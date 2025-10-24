#!/bin/bash
# Cleanup script for Phase 1 Istio control plane resources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISTIO_VERSION="1.27.3"
ISTIO_WORKDIR="$SCRIPT_DIR/.istio-${ISTIO_VERSION}"
ISTIOCTL_BIN="$ISTIO_WORKDIR/bin/istioctl"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

warn() {
    echo -e "${RED}⚠ $1${NC}"
}

abort() {
    warn "$1"
    exit 1
}

ensure_kubectl() {
    info "Validating kubectl context..."
    kubectl cluster-info >/dev/null 2>&1 || abort "kubectl is not configured or cluster is unreachable"
    success "kubectl connected"
}

ensure_istioctl() {
    if command -v istioctl >/dev/null 2>&1; then
        success "Using istioctl from PATH"
        return
    fi

    if [ -x "$ISTIOCTL_BIN" ]; then
        export PATH="$ISTIO_WORKDIR/bin:$PATH"
        success "Using cached istioctl ${ISTIO_VERSION}"
        return
    fi

    info "Downloading istioctl ${ISTIO_VERSION}..."
    local arch tmp_dir url
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) abort "Unsupported architecture: ${arch}" ;;
    esac

    url="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-${arch}.tar.gz"
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    curl -sSL "$url" -o "$tmp_dir/istio.tar.gz" || abort "Failed to download istioctl"
    tar -xzf "$tmp_dir/istio.tar.gz" -C "$tmp_dir" || abort "Failed to extract istioctl archive"

    rm -rf "$ISTIO_WORKDIR"
    mv "$tmp_dir/istio-${ISTIO_VERSION}" "$ISTIO_WORKDIR"
    chmod +x "$ISTIOCTL_BIN"
    export PATH="$ISTIO_WORKDIR/bin:$PATH"
    success "istioctl ${ISTIO_VERSION} ready"
}

remove_manifests() {
    info "Deleting Phase 1 manifests (gateway, policies, RBAC)..."
    kubectl delete -f "$SCRIPT_DIR/03-gateway.yaml" --ignore-not-found
    kubectl delete -f "$SCRIPT_DIR/02-mtls-strict.yaml" --ignore-not-found
    kubectl delete -f "$SCRIPT_DIR/00-istio-rbac.yaml" --ignore-not-found
    success "Custom Istio manifests removed"
}

remove_tls_secret() {
    local secret="aistack-tls-cert"
    info "Deleting ${secret} TLS secret if present..."
    kubectl delete secret "$secret" -n istio-system --ignore-not-found
}

uninstall_istio() {
    if ! command -v istioctl >/dev/null 2>&1; then
        warn "istioctl not available; skipping automated uninstall"
        return
    fi

    info "Running istioctl uninstall --purge..."
    if istioctl uninstall --purge --skip-confirmation >/dev/null 2>&1; then
        success "Istio control planes removed"
    else
        warn "istioctl uninstall reported issues; continuing with namespace cleanup"
    fi
}

cleanup_namespace() {
    info "Deleting istio-system namespace..."
    kubectl delete namespace istio-system --ignore-not-found --wait=false
    success "istio-system namespace deletion requested"
}

cleanup_namespaces_labels() {
    info "Removing istio-injection labels from application namespaces..."
    for ns in kserve litellm redis postgres model-watcher; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            kubectl label namespace "$ns" istio-injection- --overwrite >/dev/null 2>&1 || true
        fi
    done
    success "Namespace labels cleaned"
}

ensure_kubectl
ensure_istioctl
remove_manifests
remove_tls_secret
uninstall_istio
cleanup_namespace
cleanup_namespaces_labels

info "Phase 1 Istio cleanup initiated. Some resources may take time to terminate."
