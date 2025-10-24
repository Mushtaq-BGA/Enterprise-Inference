#!/bin/bash
# Phase 4: LiteLLM Model Registration (Production-Standard GitOps Approach)
# 
# This script uses the ConfigMap-based declarative approach for model registration,
# following Kubernetes GitOps best practices instead of API-based database mutations.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

print_header() {
    echo -e "${BLUE}$1${NC}"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "Missing required command: $1"
        exit 1
    fi
}

echo ""
print_header "========================================="
print_header "Phase 4: Model Registration (GitOps)"
print_header "========================================="
echo ""

require_command kubectl

# Configuration
KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-kserve}"
LITELLM_NAMESPACE="${LITELLM_NAMESPACE:-litellm}"

print_info "Using production-standard ConfigMap-based approach"
print_info "KServe namespace: $KSERVE_NAMESPACE"
print_info "LiteLLM namespace: $LITELLM_NAMESPACE"
echo ""

# Clean up legacy resources if they exist
print_info "Cleaning up legacy resources (if present)..."
kubectl delete deployment model-watcher -n model-watcher --ignore-not-found 2>/dev/null || true
kubectl delete configmap model-watcher-code -n model-watcher --ignore-not-found 2>/dev/null || true
kubectl delete secret model-watcher-secret -n model-watcher --ignore-not-found 2>/dev/null || true
kubectl delete clusterrole model-watcher-role --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding model-watcher-binding --ignore-not-found 2>/dev/null || true
kubectl delete serviceaccount model-watcher -n model-watcher --ignore-not-found 2>/dev/null || true
kubectl delete namespace model-watcher --ignore-not-found 2>/dev/null || true

# Check if KServe namespace exists
if ! kubectl get namespace "$KSERVE_NAMESPACE" >/dev/null 2>&1; then
    print_error "KServe namespace '$KSERVE_NAMESPACE' not found"
    print_info "Please deploy Phase 2 (Knative + KServe) first"
    exit 1
fi

# Check if LiteLLM is deployed
if ! kubectl get deployment litellm -n "$LITELLM_NAMESPACE" >/dev/null 2>&1; then
    print_error "LiteLLM deployment not found in namespace '$LITELLM_NAMESPACE'"
    print_info "Please deploy Phase 3 (LiteLLM) first"
    exit 1
fi

# Use the production-standard discovery script
if [ ! -f "$SCRIPT_DIR/discover-and-configure.sh" ]; then
    print_error "discover-and-configure.sh not found"
    exit 1
fi

chmod +x "$SCRIPT_DIR/discover-and-configure.sh"

echo ""
print_info "Discovering InferenceServices and updating LiteLLM ConfigMap..."
echo ""

# Run the discovery script in non-interactive mode (auto-confirm if new models found)
AUTO_CONFIRM=true "$SCRIPT_DIR/discover-and-configure.sh" || EXIT_CODE=$?

if [ "${EXIT_CODE:-0}" -eq 0 ]; then
    echo ""
    print_success "Phase 4 completed successfully"
    echo ""
    print_header "========================================="
    print_header "Phase 4 Summary"
    print_header "========================================="
    echo ""
    print_info "✓ Models discovered from KServe"
    print_info "✓ LiteLLM ConfigMap updated (declarative)"
    print_info "✓ LiteLLM pods restarted with new configuration"
    echo ""
    print_info "Production Standards Applied:"
    echo "  • ConfigMap-based declarative configuration"
    echo "  • Version controlled via Kubernetes API"
    echo "  • Immutable infrastructure (restart on change)"
    echo "  • GitOps compliant workflow"
    echo ""
    print_info "To re-run model discovery:"
    echo "  cd phase4-model-watcher"
    echo "  ./discover-and-configure.sh"
    echo ""
    print_info "To verify models are registered:"
    echo "  kubectl port-forward -n litellm svc/litellm 4000:4000 &"
    echo "  curl http://localhost:4000/v1/models -H 'Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef'"
    echo ""
    print_info "Next Step: Run Phase 5 for optimization and load testing"
    echo "  cd ../phase5-optimization && ./deploy-phase5.sh"
    echo ""
else
    print_error "Phase 4 failed with exit code $EXIT_CODE"
    print_info "Check the output above for errors"
    exit 1
fi
