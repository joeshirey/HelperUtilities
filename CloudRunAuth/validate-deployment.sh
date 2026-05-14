#!/usr/bin/env bash
#
# validate-deployment.sh
#
# End-to-end validation harness for setup-cloud-run-oauth.sh.
# Deploys a temporary hello-world Cloud Run service, invokes the setup script,
# verifies the resulting 302 OAuth redirect and IAM bindings, and cleans up.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*"; exit 1; }

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}${prompt_text}${NC} [${default}]: ")" value
    printf -v "$var_name" '%s' "${value:-$default}"
  else
    read -rp "$(echo -e "${BOLD}${prompt_text}${NC}: ")" value
    [[ -z "$value" ]] && error "A value is required."
    printf -v "$var_name" '%s' "$value"
  fi
}

confirm() {
  local prompt_text="$1"
  read -rp "$(echo -e "${BOLD}${prompt_text}${NC} [Y/n]: ")" answer
  [[ "${answer:-Y}" =~ ^[Yy] ]]
}

echo ""
echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD} Cloud Run OAuth Setup - End-to-End Validation${NC}"
echo -e "${BOLD}====================================================${NC}"
echo ""

if ! command -v gcloud &>/dev/null; then
  error "gcloud CLI is not installed."
fi

if ! gcloud auth print-access-token &>/dev/null; then
  error "gcloud is not authenticated or credentials have expired. Run: gcloud auth login"
fi
GCLOUD_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
info "Authenticated as: ${GCLOUD_ACCOUNT}"
echo ""

prompt PROJECT_ID "GCP Project ID"
prompt REGION "Cloud Run region" "us-central1"
prompt ALLOWED_DOMAINS_INPUT "Allowed email domains (comma-separated)"

TEST_SERVICE_NAME="oauth-test-${RANDOM}"
YAML_FILE="service-${TEST_SERVICE_NAME}-oauth.yaml"

cleanup() {
  echo ""
  info "Cleaning up temporary resources..."
  if gcloud run services describe "$TEST_SERVICE_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud run services delete "$TEST_SERVICE_NAME" --region="$REGION" --project="$PROJECT_ID" --quiet &>/dev/null || true
    success "Deleted temporary service: $TEST_SERVICE_NAME"
  fi
  if [[ -f "$YAML_FILE" ]]; then
    rm -f "$YAML_FILE"
    success "Removed temporary YAML: $YAML_FILE"
  fi
}
trap cleanup EXIT SIGINT SIGTERM

echo ""
info "Deploying temporary sample service ($TEST_SERVICE_NAME)..."
gcloud run deploy "$TEST_SERVICE_NAME" \
  --image="gcr.io/google-samples/hello-app:1.0" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --allow-unauthenticated \
  --quiet

SERVICE_URL=$(gcloud run services describe "$TEST_SERVICE_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format='value(status.url)')

success "Temporary service deployed successfully!"
info "Service URL: $SERVICE_URL"
echo ""
