#!/bin/bash
# Phase 1: Bootstrap namespaces + Istio 1.27.3 control plane
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$SCRIPT_DIR"

ISTIO_VERSION="1.27.3"
ISTIO_WORKDIR="$SCRIPT_DIR/.istio-${ISTIO_VERSION}"
ISTIOCTL_BIN="$ISTIO_WORKDIR/bin/istioctl"

echo "========================================="
echo "Phase 1: Base Cluster + Istio ${ISTIO_VERSION}"
echo "========================================="

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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

abort() {
    print_error "$1"
    exit 1
}

wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}

    print_info "Waiting for deployment $deployment in namespace $namespace..."
    if kubectl rollout status "deployment/${deployment}" -n "$namespace" --timeout="${timeout}s" > /dev/null; then
        print_success "Deployment $deployment is ready"
    else
        kubectl get pods -n "$namespace"
        abort "Deployment $deployment failed to become ready"
    fi
}

ensure_kubectl() {
    print_info "Validating kubectl context..."
    if ! kubectl cluster-info >/dev/null 2>&1; then
        abort "kubectl is not configured or cannot reach the cluster"
    fi
    local version
    version=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}' || echo "unknown")
    print_success "kubectl connected to cluster (server ${version})"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            abort "Unsupported architecture: ${arch}"
            ;;
    esac
}

ensure_istioctl() {
    if [ -x "$ISTIOCTL_BIN" ]; then
        print_success "istioctl ${ISTIO_VERSION} already available"
        export PATH="$ISTIO_WORKDIR/bin:$PATH"
        return
    fi

    if command -v istioctl >/dev/null 2>&1; then
        local client
        client=$(istioctl version --remote=false 2>/dev/null | awk -F': ' '/client version/ {print $2}')
        if [[ "$client" == "$ISTIO_VERSION" ]]; then
            print_success "Using existing istioctl ${ISTIO_VERSION} from PATH"
            return
        fi
        print_info "Found istioctl ${client}, but ${ISTIO_VERSION} is required. Downloading dedicated binary..."
    else
        print_info "istioctl not found. Downloading ${ISTIO_VERSION}..."
    fi

    local arch
    arch=$(detect_arch)
    local url="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-${arch}.tar.gz"

    mkdir -p "$ISTIO_WORKDIR"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    curl -sSL "$url" -o "$tmp_dir/istio.tar.gz" || abort "Failed to download istioctl from ${url}"
    tar -xzf "$tmp_dir/istio.tar.gz" -C "$tmp_dir" || abort "Failed to extract istioctl archive"

    rm -rf "$ISTIO_WORKDIR"
    mv "$tmp_dir/istio-${ISTIO_VERSION}" "$ISTIO_WORKDIR"

    rm -rf "$tmp_dir"
    trap - EXIT

    chmod +x "$ISTIOCTL_BIN"
    export PATH="$ISTIO_WORKDIR/bin:$PATH"
    print_success "Downloaded istioctl ${ISTIO_VERSION}"
}

create_namespaces() {
    print_info "Creating core namespaces..."
    kubectl apply -f "$PHASE_DIR/00-namespaces.yaml"
    kubectl apply -f "$PHASE_DIR/00-istio-rbac.yaml"
    for ns in istio-system kserve litellm redis postgres model-watcher; do
        kubectl get namespace "$ns" >/dev/null 2>&1 || abort "Namespace ${ns} failed to create"
    done
    print_success "Namespaces and RBAC ready"
}

install_istio() {
    print_info "Installing Istio control plane (profile: minimal)..."
    istioctl install -f "$PHASE_DIR/01-istio-minimal.yaml" --skip-confirmation
    print_success "Istio ${ISTIO_VERSION} control plane applied"

    wait_for_deployment istio-system istiod 300
    wait_for_deployment istio-system istio-ingressgateway 300
}

configure_security() {
    print_info "Applying mesh security policies..."
    kubectl apply -f "$PHASE_DIR/02-mtls-strict.yaml"
    print_success "STRICT mTLS and authorization policies applied"
}

ensure_gateway_tls() {
    print_info "Ensuring development TLS secret exists..."
    local secret_name="aistack-tls-cert"
    if kubectl get secret "$secret_name" -n istio-system >/dev/null 2>&1; then
        print_info "TLS secret ${secret_name} already present"
        return
    fi

    local tmp_key tmp_crt
    tmp_key=$(mktemp)
    tmp_crt=$(mktemp)

    openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
        -subj '/O=AI Stack Inc./CN=*.aistack.local' \
        -keyout "$tmp_key" -out "$tmp_crt" >/dev/null 2>&1 || abort "Failed to generate self-signed certificate"

    kubectl create secret tls "$secret_name" -n istio-system \
        --key="$tmp_key" --cert="$tmp_crt"
    print_success "Created TLS secret ${secret_name}"

    rm -f "$tmp_key" "$tmp_crt"
}

deploy_gateway() {
    print_info "Deploying unified Istio Gateway..."
    kubectl apply -f "$PHASE_DIR/03-gateway.yaml"
    print_success "Gateway manifest applied"
}

deploy_network_policies() {
    print_info "Deploying NetworkPolicies for defense in depth..."
    kubectl apply -f "$PHASE_DIR/04-network-policies.yaml"
    print_success "NetworkPolicies applied"
}

report_endpoints() {
    local http_port https_port node_ip
    http_port=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' || echo "")
    https_port=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' || echo "")
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' || echo "")

    print_success "Istio control plane and ingress are ready"
    echo ""
    echo "Ingress endpoints (NodePort):"
    echo "  HTTP : http://${node_ip}:${http_port}"
    echo "  HTTPS: https://${node_ip}:${https_port}"
    echo ""
}

verify_sidecar_labels() {
    print_info "Verifying sidecar injection labels..."
    for ns in kserve litellm redis postgres model-watcher; do
        local label
        label=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || echo "")
        if [[ "$label" != "enabled" ]]; then
            abort "Namespace ${ns} is missing istio-injection=enabled label"
        fi
        print_success "Namespace ${ns} is ready for sidecar injection"
    done
}

ensure_kubectl
ensure_istioctl
create_namespaces
install_istio
configure_security
ensure_gateway_tls
deploy_gateway
# deploy_network_policies  # DISABLED: NetworkPolicies block external model downloads from HuggingFace
verify_sidecar_labels
report_endpoints

echo "========================================="
echo "Phase 1 complete"
echo "Next: cd ../phase2-knative-kserve && ./deploy-phase2.sh"
echo "========================================="
