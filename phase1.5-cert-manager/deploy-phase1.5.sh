#!/bin/bash
# Phase 1.5: cert-manager Installation
# Provides automated TLS certificate management for Kubernetes
# Required for securing Istio Gateway with public HTTPS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

echo "=========================================="
echo "Phase 1.5: Installing cert-manager v1.15.3"
echo "=========================================="

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please ensure Kubernetes is installed."
    exit 1
fi

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

echo ""
log_info "Installing cert-manager CRDs and core components..."

# Download and apply cert-manager manifests
CERT_MANAGER_VERSION="v1.15.3"
CERT_MANAGER_URL="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

log_info "Downloading cert-manager ${CERT_MANAGER_VERSION}..."
curl -sL "$CERT_MANAGER_URL" | kubectl apply -f -

# Wait for cert-manager to be ready
echo ""
log_info "Waiting for cert-manager pods to be ready (may take 2-3 minutes)..."
kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/instance=cert-manager \
    -n cert-manager \
    --timeout=300s

echo ""
log_success "cert-manager pods are ready"

# Verify cert-manager webhook is working
echo ""
log_info "Verifying cert-manager webhook..."
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=120s >/dev/null
sleep 5  # Give webhook time to publish fresh serving certificate

apply_manifest_with_retry() {
    local manifest=$1
    local retries=${2:-8}
    local delay=${3:-10}
    local attempt=1

    if ! grep -qE '^[[:space:]]*[^#[:space:]]' "$manifest"; then
        log_info "$(basename "$manifest") contains no active resources; skipping"
        return 0
    fi

    while [ $attempt -le $retries ]; do
        if kubectl apply -f "$manifest"; then
            log_success "Applied $(basename "$manifest")"
            return 0
        fi
        log_info "Webhook not ready yet (attempt $attempt/$retries). Retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    log_error "Failed to apply $(basename "$manifest") after $retries attempts"
    return 1
}

# Apply certificate issuers
echo ""
log_info "Creating certificate issuers..."
apply_manifest_with_retry "$SCRIPT_DIR/01-letsencrypt-staging.yaml"
apply_manifest_with_retry "$SCRIPT_DIR/02-letsencrypt-prod.yaml"
apply_manifest_with_retry "$SCRIPT_DIR/03-selfsigned-issuer.yaml"

log_info "Applying example certificate (optional resources)..."
if ! apply_manifest_with_retry "$SCRIPT_DIR/04-example-certificate.yaml" 3 10; then
    log_info "Skipping example certificate after repeated failures"
fi

# Verify issuers
echo ""
log_info "Verifying certificate issuers..."
sleep 5
kubectl get clusterissuers

echo ""
echo "=========================================="
log_success "Phase 1.5 Complete: cert-manager installed"
echo "=========================================="
echo ""
echo "Certificate issuers available:"
echo "  • letsencrypt-staging (for testing)"
echo "  • letsencrypt-prod (for production)"
echo "  • selfsigned-issuer (for internal use)"
echo ""
echo "Next steps:"
echo "1. Update email address in issuer manifests:"
echo "   - 01-letsencrypt-staging.yaml"
echo "   - 02-letsencrypt-prod.yaml"
echo ""
echo "2. For public HTTPS, you need:"
echo "   - A public domain name pointing to your cluster"
echo "   - Ports 80 and 443 accessible from internet"
echo "   - DNS A record: yourdomain.com -> $(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo 'NODE_IP')"
echo ""
echo "3. See 04-example-certificate.yaml for usage examples"
echo ""
