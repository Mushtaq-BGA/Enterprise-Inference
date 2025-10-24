#!/bin/bash
# Cleanup script for Phase 2 Knative + KServe stack
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

# Remove sample InferenceService if present
info "Deleting sample InferenceService..."
kubectl delete -f "$SCRIPT_DIR/90-sample-inferenceservice.yaml" --ignore-not-found

info "Deleting KServe configuration and runtimes..."
kubectl delete -f "$SCRIPT_DIR/12-kserve-config.yaml" --ignore-not-found
kubectl delete -f "$SCRIPT_DIR/11-openvino-runtime.yaml" --ignore-not-found

info "Deleting KServe controller and CRDs (async)..."
kubectl delete --wait=false -f "$SCRIPT_DIR/10-kserve.yaml" --ignore-not-found

info "Deleting Knative configuration..."
kubectl delete --wait=false -f "$SCRIPT_DIR/03-knative-config.yaml" --ignore-not-found
kubectl delete --wait=false -f "$SCRIPT_DIR/02-knative-istio-networking.yaml" --ignore-not-found
kubectl delete --wait=false -f "$SCRIPT_DIR/01-knative-serving-core.yaml" --ignore-not-found
kubectl delete --wait=false -f "$SCRIPT_DIR/00-knative-serving-crds.yaml" --ignore-not-found

success "Phase 2 resources removed"

info "Note: namespaces (knative-serving, kserve) and CRDs may take a moment to fully terminate."
