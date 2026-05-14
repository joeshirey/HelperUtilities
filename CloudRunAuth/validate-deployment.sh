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

echo ""
echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD} Cloud Run OAuth Setup - End-to-End Validation${NC}"
echo -e "${BOLD}====================================================${NC}"
echo ""

if ! command -v gcloud &>/dev/null; then
  error "gcloud CLI is not installed."
fi

GCLOUD_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
if [[ -z "$GCLOUD_ACCOUNT" ]]; then
  error "gcloud is not authenticated. Run: gcloud auth login"
fi
info "Authenticated as: ${GCLOUD_ACCOUNT}"
echo ""
