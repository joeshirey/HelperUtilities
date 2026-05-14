#!/usr/bin/env bash
#
# setup-cloud-run-oauth.sh
#
# Adds domain-restricted Google Sign-In to a Cloud Run service using
# oauth2-proxy as a sidecar container. No application code changes required.
#
# Usage: bash setup-cloud-run-oauth.sh
#
# See cloud-run-oauth-setup.md for the full guide, including alternative
# approaches (code-level auth, IAP + Load Balancer).

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors and helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}${prompt_text}${NC} [${default}]: ")" value
    eval "$var_name=\"${value:-$default}\""
  else
    read -rp "$(echo -e "${BOLD}${prompt_text}${NC}: ")" value
    [[ -z "$value" ]] && error "A value is required."
    eval "$var_name=\"$value\""
  fi
}

confirm() {
  local prompt_text="$1"
  read -rp "$(echo -e "${BOLD}${prompt_text}${NC} [Y/n]: ")" answer
  [[ "${answer:-Y}" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} Cloud Run OAuth Setup${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "This script adds Google Sign-In to a Cloud Run service using"
echo "oauth2-proxy as a sidecar container. No application code changes"
echo "are required — auth is handled entirely at the infrastructure level."
echo ""
echo "Prerequisites:"
echo "  - gcloud CLI installed and authenticated"
echo "  - An existing Cloud Run service"
echo ""

if ! command -v gcloud &>/dev/null; then
  error "gcloud CLI is not installed. Install it from https://cloud.google.com/sdk/docs/install"
fi

GCLOUD_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
if [[ -z "$GCLOUD_ACCOUNT" ]]; then
  error "gcloud is not authenticated. Run: gcloud auth login"
fi
info "Authenticated as: ${GCLOUD_ACCOUNT}"
echo ""

# ---------------------------------------------------------------------------
# Gather configuration
# ---------------------------------------------------------------------------
echo -e "${BOLD}--- Configuration ---${NC}"
echo ""

prompt PROJECT_ID "GCP Project ID"
prompt SERVICE_NAME "Cloud Run service name"
prompt REGION "Cloud Run region" "us-central1"
prompt ALLOWED_DOMAINS_INPUT "Allowed email domains (comma-separated)"
prompt HEALTH_PATH "Startup probe path (use / for static sites, /health or /api/health for APIs)" "/"

echo ""
echo -e "${YELLOW}If your app's Dockerfile hardcodes a port (e.g., --port 8080), the sidecar${NC}"
echo -e "${YELLOW}needs to override the CMD so the app listens on 8081 instead.${NC}"
echo -e "${YELLOW}If your app respects the PORT env var, you can skip this.${NC}"
echo ""
if confirm "Does the app need a CMD override to listen on port 8081?"; then
  echo ""
  echo "Enter the full command to start your app on port 8081."
  echo "Examples:"
  echo "  uvicorn myapp:app --host 0.0.0.0 --port 8081"
  echo "  node server.js"
  echo "  python -m flask run --host 0.0.0.0 --port 8081"
  echo ""
  prompt APP_CMD_OVERRIDE "Command + args"
  read -ra CMD_PARTS <<< "$APP_CMD_OVERRIDE"
  APP_COMMAND="${CMD_PARTS[0]}"
  APP_ARGS=("${CMD_PARTS[@]:1}")
else
  APP_COMMAND=""
  APP_ARGS=()
fi

# Normalize: trim spaces around commas
ALLOWED_DOMAINS_INPUT=$(echo "$ALLOWED_DOMAINS_INPUT" | sed 's/ *, */,/g')

echo ""

# ---------------------------------------------------------------------------
# Validate and retrieve existing service info
# ---------------------------------------------------------------------------
info "Retrieving existing service configuration..."

if ! gcloud run services describe "$SERVICE_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format='value(metadata.name)' &>/dev/null; then
  error "Cloud Run service '$SERVICE_NAME' not found in region '$REGION' of project '$PROJECT_ID'."
fi

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format='value(status.url)')

APP_IMAGE=$(gcloud run services describe "$SERVICE_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format='value(spec.template.spec.containers[0].image)')

success "Service found."
info "Service URL: $SERVICE_URL"
info "App image:   $APP_IMAGE"

CALLBACK_URL="${SERVICE_URL}/oauth2/callback"

# Retrieve existing app env vars (excluding PORT, which we set explicitly)
info "Retrieving existing environment variables..."
APP_ENV_YAML=$(gcloud run services describe "$SERVICE_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
svc = json.load(sys.stdin)
containers = svc.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [{}])
envs = containers[0].get('env', [])
for e in envs:
    if e.get('name') == 'PORT':
        continue
    name = e.get('name', '')
    val = e.get('value', '')
    print(f'        - name: {name}')
    print(f'          value: \"{val}\"')
" 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# Set up Artifact Registry remote repo for quay.io
# ---------------------------------------------------------------------------
echo ""
info "Checking for Artifact Registry remote repository for quay.io..."

AR_REPO="quay-remote"
AR_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/oauth2-proxy/oauth2-proxy:v7.7.1"

if gcloud artifacts repositories describe "$AR_REPO" \
  --location="$REGION" \
  --project="$PROJECT_ID" &>/dev/null 2>&1; then
  success "Remote repository '${AR_REPO}' already exists."
else
  info "Creating Artifact Registry remote repository '${AR_REPO}' to proxy quay.io..."
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --mode=remote-repository \
    --remote-docker-repo=https://quay.io \
    --project="$PROJECT_ID"
  success "Remote repository created."
fi

info "oauth2-proxy image: $AR_IMAGE"

echo ""
echo -e "${BOLD}--- Configuration Summary ---${NC}"
echo "  Project:          $PROJECT_ID"
echo "  Service:          $SERVICE_NAME"
echo "  Region:           $REGION"
echo "  App image:        $APP_IMAGE"
echo "  Service URL:      $SERVICE_URL"
echo "  Allowed domains:  $ALLOWED_DOMAINS_INPUT"
echo "  Health probe:     $HEALTH_PATH"
if [[ -n "$APP_COMMAND" ]]; then
echo "  CMD override:     $APP_CMD_OVERRIDE"
fi
echo ""

if ! confirm "Proceed?"; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Manual step: OAuth Consent Screen
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} MANUAL STEP: OAuth Consent Screen${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "Configure the OAuth consent screen in the Cloud Console."
echo ""
echo "1. Open this URL:"
echo ""
echo -e "   ${BLUE}https://console.cloud.google.com/apis/credentials/consent?project=${PROJECT_ID}${NC}"
echo ""
echo "2. Set User Type to ${BOLD}External${NC} (not Internal!)"
echo "   Internal blocks users outside your Workspace org at Google's"
echo "   sign-in page — before your proxy ever sees the request."
echo ""
echo "3. Fill in required fields:"
echo "   - App name: any name (e.g., '${SERVICE_NAME}')"
echo "   - User support email: your email"
echo "   - Developer contact: your email"
echo ""
echo "4. On the Scopes page, add: ${BOLD}email${NC}, ${BOLD}profile${NC}"
echo ""
echo "5. Skip Test Users, click Save"
echo ""
echo "6. Back on the dashboard, click ${BOLD}Publish App${NC}"
echo "   (required — Testing mode only allows explicitly listed users)"
echo ""
echo -e "${YELLOW}If already configured, verify it is set to External and published.${NC}"
echo ""

read -rp "$(echo -e "${BOLD}Press Enter when done...${NC}")"

# ---------------------------------------------------------------------------
# Manual step: Create OAuth Client ID
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} MANUAL STEP: Create OAuth Client ID${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "Each Cloud Run service needs its own OAuth client (different redirect URI)."
echo "The consent screen configured above is shared across all clients."
echo ""
echo "1. Open this URL:"
echo ""
echo -e "   ${BLUE}https://console.cloud.google.com/apis/credentials?project=${PROJECT_ID}${NC}"
echo ""
echo "2. Click ${BOLD}+ Create Credentials${NC} > ${BOLD}OAuth client ID${NC}"
echo ""
echo "3. Application type: ${BOLD}Web application${NC}"
echo ""
echo "4. Under ${BOLD}Authorized redirect URIs${NC}, add:"
echo ""
echo -e "   ${GREEN}${CALLBACK_URL}${NC}"
echo ""
echo "   (oauth2-proxy uses /oauth2/callback, not /auth/callback)"
echo ""
echo "5. Click Create, then copy the Client ID and Client Secret"
echo ""
echo -e "${YELLOW}Do NOT use an auto-generated IAP OAuth client — those are${NC}"
echo -e "${YELLOW}locked and don't allow adding redirect URIs.${NC}"
echo ""

prompt GOOGLE_CLIENT_ID "Enter the OAuth Client ID"
prompt GOOGLE_CLIENT_SECRET "Enter the OAuth Client Secret"

# ---------------------------------------------------------------------------
# Generate cookie secret (must be exactly 16, 24, or 32 bytes)
# ---------------------------------------------------------------------------
COOKIE_SECRET=$(openssl rand -hex 16 2>/dev/null \
  || python3 -c "import os; print(os.urandom(16).hex())")

# ---------------------------------------------------------------------------
# Generate service YAML
# ---------------------------------------------------------------------------
YAML_PATH="$(pwd)/service-${SERVICE_NAME}-oauth.yaml"

info "Generating service YAML at: $YAML_PATH"

# Build the app env vars section
APP_ENV_SECTION=""
if [[ -n "$APP_ENV_YAML" ]]; then
  APP_ENV_SECTION="$APP_ENV_YAML
"
fi

# Build --email-domain args (one per domain, not comma-separated)
EMAIL_DOMAIN_ARGS=""
IFS=',' read -ra DOMAIN_LIST <<< "$ALLOWED_DOMAINS_INPUT"
for domain in "${DOMAIN_LIST[@]}"; do
  EMAIL_DOMAIN_ARGS+="        - \"--email-domain=${domain}\""$'\n'
done

# Build optional CMD override section
CMD_SECTION=""
if [[ -n "$APP_COMMAND" ]]; then
  CMD_SECTION="        command: [\"${APP_COMMAND}\"]"$'\n'
  CMD_SECTION+="        args: ["
  first=true
  for arg in "${APP_ARGS[@]}"; do
    if $first; then first=false; else CMD_SECTION+=", "; fi
    CMD_SECTION+="\"${arg}\""
  done
  CMD_SECTION+="]"$'\n'
fi

# NOTE: oauth2-proxy v7.x does not reliably pick up OAUTH2_PROXY_UPSTREAM
# as an environment variable. Using CLI args instead ensures the upstream
# is properly registered. See cloud-run-oauth-setup.md for details.
cat > "$YAML_PATH" << YAMLEOF
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
spec:
  template:
    metadata:
      annotations:
        run.googleapis.com/container-dependencies: '{"oauth-proxy":["app"]}'
    spec:
      containers:
      - name: oauth-proxy
        image: ${AR_IMAGE}
        args:
        - "--provider=google"
        - "--client-id=${GOOGLE_CLIENT_ID}"
        - "--client-secret=${GOOGLE_CLIENT_SECRET}"
        - "--cookie-secret=${COOKIE_SECRET}"
${EMAIL_DOMAIN_ARGS}        - "--upstream=http://localhost:8081/"
        - "--http-address=0.0.0.0:8080"
        - "--reverse-proxy=true"
        - "--skip-provider-button=true"
        - "--cookie-secure=true"
        ports:
        - containerPort: 8080
      - name: app
        image: ${APP_IMAGE}
${CMD_SECTION}        startupProbe:
          httpGet:
            path: ${HEALTH_PATH}
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 6
          timeoutSeconds: 5
        env:
        - name: PORT
          value: "8081"
${APP_ENV_SECTION}
YAMLEOF

success "Service YAML generated."
echo ""

if confirm "Review the YAML before deploying?"; then
  echo ""
  echo -e "${BOLD}--- service YAML ---${NC}"
  cat "$YAML_PATH"
  echo ""
  echo -e "${BOLD}--- end ---${NC}"
  echo ""
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
if confirm "Deploy ${SERVICE_NAME} with oauth2-proxy sidecar now?"; then
  info "Deploying (this may take a few minutes)..."
  gcloud run services replace "$YAML_PATH" \
    --region="$REGION" \
    --project="$PROJECT_ID"

  # Ensure the service is publicly accessible (oauth2-proxy handles auth)
  info "Ensuring allUsers invoker binding (oauth2-proxy handles auth, not IAM)..."
  gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
    --member="allUsers" \
    --role="roles/run.invoker" \
    --region="$REGION" \
    --project="$PROJECT_ID" 2>/dev/null || true

  # Get the (possibly updated) service URL
  NEW_SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format='value(status.url)')
  NEW_CALLBACK_URL="${NEW_SERVICE_URL}/oauth2/callback"

  echo ""
  success "Deployment complete!"
  echo ""

  if [[ "$NEW_SERVICE_URL" != "$SERVICE_URL" ]]; then
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW} SERVICE URL CHANGED${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo "The Cloud Run URL changed during deployment:"
    echo "  Old: $SERVICE_URL"
    echo "  New: $NEW_SERVICE_URL"
    echo ""
    echo "You MUST update the Authorized Redirect URI in your OAuth client:"
    echo ""
    echo "1. Go to: https://console.cloud.google.com/apis/credentials?project=${PROJECT_ID}"
    echo "2. Click on your OAuth client"
    echo "3. Update the redirect URI to:"
    echo -e "   ${GREEN}${NEW_CALLBACK_URL}${NC}"
    echo ""
  fi

  echo -e "${BOLD}--- Summary ---${NC}"
  echo ""
  echo "  Service URL:     $NEW_SERVICE_URL"
  echo "  Callback URL:    $NEW_CALLBACK_URL"
  echo "  Allowed domains: $ALLOWED_DOMAINS_INPUT"
  echo "  Service YAML:    $YAML_PATH"
  echo ""
  echo "Test by opening the service URL in your browser. You should be"
  echo "redirected to Google Sign-In. Only accounts from the allowed"
  echo "domains will be granted access."
  echo ""
  echo -e "${YELLOW}To update your app image in the future, use:${NC}"
  echo "  gcloud run deploy ${SERVICE_NAME} --container app --image <NEW_IMAGE> \\"
  echo "    --region=${REGION} --project=${PROJECT_ID}"
  echo ""
  echo -e "${YELLOW}Do NOT use 'gcloud run deploy --source' — it will remove the sidecar.${NC}"
else
  echo ""
  info "Skipping deployment. To deploy manually, run:"
  echo ""
  echo "  gcloud run services replace $YAML_PATH \\"
  echo "    --region=$REGION --project=$PROJECT_ID"
  echo ""
fi

echo ""
success "Setup complete!"
echo ""
echo "For troubleshooting, see: cloud-run-oauth-setup.md"
echo ""
