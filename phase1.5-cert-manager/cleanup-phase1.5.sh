#!/bin/bash
# Cleanup script for Phase 1.5 cert-manager stack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

CERT_MANAGER_VERSION="v1.15.3"
CERT_MANAGER_URL="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

info "Deleting example certificates and issuers..."
kubectl delete -f "$SCRIPT_DIR/04-example-certificate.yaml" --ignore-not-found
kubectl delete -f "$SCRIPT_DIR/03-selfsigned-issuer.yaml" --ignore-not-found
kubectl delete -f "$SCRIPT_DIR/02-letsencrypt-prod.yaml" --ignore-not-found
kubectl delete -f "$SCRIPT_DIR/01-letsencrypt-staging.yaml" --ignore-not-found

info "Deleting cert-manager core components (${CERT_MANAGER_VERSION})..."
kubectl delete -f "$CERT_MANAGER_URL" --ignore-not-found

success "Phase 1.5 resources removed"

info "Note: namespace cert-manager will remain unless deleted manually."
