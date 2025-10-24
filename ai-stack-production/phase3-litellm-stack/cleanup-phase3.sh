#!/bin/bash
# Cleanup script for Phase 3 LiteLLM stack
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

info "Deleting LiteLLM VirtualService..."
kubectl delete -f "$SCRIPT_DIR/04-litellm-virtualservice.yaml" --ignore-not-found

info "Deleting LiteLLM deployment, service, HPA, and PDB..."
kubectl delete -f "$SCRIPT_DIR/03-litellm-deployment.yaml" --ignore-not-found

info "Deleting LiteLLM configuration..."
kubectl delete configmap litellm-config -n litellm --ignore-not-found

info "Deleting Redis stack..."
kubectl delete -f "$SCRIPT_DIR/01-redis-destinationrule.yaml" --ignore-not-found
kubectl delete -f "$SCRIPT_DIR/01-redis.yaml" --ignore-not-found

info "Deleting Postgres stack..."
kubectl delete -f "$SCRIPT_DIR/00-postgres-destinationrule.yaml" --ignore-not-found
kubectl delete -f "$SCRIPT_DIR/00-postgres.yaml" --ignore-not-found

success "Phase 3 resources removed"

info "Note: namespaces (litellm, redis, postgres) are preserved. Delete manually if desired."
