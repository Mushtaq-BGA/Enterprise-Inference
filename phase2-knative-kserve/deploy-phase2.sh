#!/bin/bash
# Phase 2: Deploy Knative + KServe + Autoscaling
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/scripts/lib/cluster-domain.sh"
CLUSTER_DOMAIN="$(ensure_cluster_domain)"

echo "========================================="
echo "Phase 2: Knative + KServe + Autoscaling"
echo "========================================="

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

ensure_namespace() {
    local ns=$1

    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        print_info "Namespace $ns already exists"
        return
    fi

    print_info "Creating namespace $ns..."
    case "$ns" in
        kserve)
            cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: kserve
  labels:
    name: kserve
    istio-injection: enabled
    serving.knative.dev/release: devel
EOF
            ;;
        *)
            cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
EOF
            ;;
    esac
    print_success "Namespace $ns created"
}

# Function to wait for deployment
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}
    
    print_info "Waiting for deployment $deployment in namespace $namespace..."
    if kubectl wait --for=condition=available --timeout=${timeout}s \
        deployment/$deployment -n $namespace 2>/dev/null; then
        print_success "Deployment $deployment is ready"
        return 0
    else
        print_error "Deployment $deployment failed to become ready"
        kubectl get pods -n $namespace -l app=$deployment
        return 1
    fi
}

wait_for_service_endpoints() {
    local namespace=$1
    local service=$2
    local timeout=${3:-120}
    local interval=5
    local waited=0

    print_info "Waiting for service $service endpoints in namespace $namespace..."
    while [ $waited -lt $timeout ]; do
        local endpoints
        endpoints=$(kubectl get endpoints "$service" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
        if [[ -n "$endpoints" ]]; then
            print_success "Service $service has active endpoints"
            return 0
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
    print_error "Timed out waiting for service $service endpoints"
    kubectl get endpoints "$service" -n "$namespace"
    return 1
}

# Check prerequisites
print_info "Checking prerequisites..."

# Check if Istio is installed
if ! kubectl get deployment istiod -n istio-system &> /dev/null; then
    print_error "Istio not found. Please run Phase 1 first."
    exit 1
fi
print_success "Istio is installed"

# Ensure required namespaces exist (Phase 1 fallback)
ensure_namespace "kserve"

print_success "Required namespaces are ready"

# Download manifests if not present
if [ ! -f "$PHASE_DIR/00-knative-serving-crds.yaml" ]; then
    print_info "Downloading Knative and KServe manifests..."
    bash "$PHASE_DIR/download-manifests.sh"
fi

# Step 1: Install Knative Serving CRDs
print_info "Installing Knative Serving CRDs..."
kubectl apply -f "$PHASE_DIR/00-knative-serving-crds.yaml"
sleep 5
print_success "Knative Serving CRDs installed"

# Step 2: Install Knative Serving Core
print_info "Installing Knative Serving Core..."
kubectl apply -f "$PHASE_DIR/01-knative-serving-core.yaml"

# Wait for Knative controller
wait_for_deployment knative-serving controller 300

# Wait for Knative webhook
wait_for_deployment knative-serving webhook 300

# Wait for Knative activator
wait_for_deployment knative-serving activator 300

# Wait for Knative autoscaler
wait_for_deployment knative-serving autoscaler 300

print_success "Knative Serving Core installed"

# Step 3: Configure Knative Serving
print_info "Configuring Knative Serving (autoscaling, domain, network)..."
print_info "Detected cluster domain: $CLUSTER_DOMAIN"

# Create temporary config with cluster domain substituted
KNATIVE_CONFIG_TEMP=$(mktemp)
sed "s/__CLUSTER_DOMAIN__/${CLUSTER_DOMAIN}/g" "$PHASE_DIR/03-knative-config.yaml" > "$KNATIVE_CONFIG_TEMP"

kubectl apply -f "$KNATIVE_CONFIG_TEMP"
rm -f "$KNATIVE_CONFIG_TEMP"

print_success "Knative Serving configured with domain: $CLUSTER_DOMAIN"

# Step 4: Install Knative Istio Networking
print_info "Installing Knative Istio Networking..."
kubectl apply -f "$PHASE_DIR/02-knative-istio-networking.yaml"

# Wait for net-istio-controller
wait_for_deployment knative-serving net-istio-controller 300

# Wait for net-istio-webhook
wait_for_deployment knative-serving net-istio-webhook 300

print_success "Knative Istio Networking installed"

# Verify Knative installation
print_info "Verifying Knative installation..."
kubectl get pods -n knative-serving

# Step 5: Install KServe (CRDs + controller)
print_info "Installing KServe..."
kubectl apply --server-side --force-conflicts -f "$PHASE_DIR/10-kserve.yaml"

# Wait for KServe controller
wait_for_deployment kserve kserve-controller-manager 300
wait_for_deployment kserve kserve-localmodel-controller-manager 300
wait_for_service_endpoints kserve kserve-webhook-server-service 120

print_success "KServe installed"

# Step 6: Install ClusterServingRuntime for OpenVINO with HuggingFace support
print_info "Installing OpenVINO ClusterServingRuntime with HuggingFace pull support..."
kubectl apply -f "$PHASE_DIR/11-openvino-runtime-hf.yaml"
print_success "OpenVINO runtime installed"

# Verify runtime is created
kubectl get clusterservingruntimes.serving.kserve.io kserve-openvino-hf || true

# Step 7: Configure KServe
print_info "Configuring KServe (storage, ingress)..."
kubectl apply -f "$PHASE_DIR/12-kserve-config.yaml"
print_success "KServe configured"

# Verify KServe installation
print_info "Verifying KServe installation..."
kubectl get pods -n kserve
kubectl get clusterservingruntimes.serving.kserve.io

# Step 8: Deploy sample InferenceService with HuggingFace direct pull
if [[ "${SKIP_SAMPLE_INFERENCESERVICE:-false}" == "true" ]]; then
    print_info "Skipping sample InferenceService (SKIP_SAMPLE_INFERENCESERVICE=true)"
else
    print_info "Deploying sample InferenceService (Qwen3-4B-INT4 with HuggingFace direct pull)..."
    print_info "Using auto-configuration to adapt to available CPU resources..."
    print_info "Note: Model will be downloaded directly from HuggingFace on first pod startup (~2GB download)"
    
    # Use auto-configuration script to detect CPU and set optimal replica limits
    bash "$PHASE_DIR/auto-configure-inferenceservice.sh"

    print_info "Starting non-blocking readiness check for InferenceService..."
    (
        sleep 30  # Give time for pod to start and download model
        if kubectl wait --for=condition=Ready --timeout=600s \
            pod -n kserve -l serving.kserve.io/inferenceservice=qwen3-4b-int4-ov 2>/dev/null; then
            print_success "Sample InferenceService pod is running"
        else
            print_error "Sample InferenceService pod did not become ready within 10 minutes"
        fi
    ) &
    SAMPLE_WAIT_PID=$!
    print_info "Background wait PID: ${SAMPLE_WAIT_PID}. Script will continue; check status with 'kubectl get pods -n kserve'."

    # Show initial InferenceService status
    kubectl get inferenceservice -n kserve
    kubectl get pods -n kserve -l serving.kserve.io/inferenceservice=qwen3-4b-int4-ov

    print_success "Sample InferenceService applied"
    print_info "Model download continues in background. Monitor with 'kubectl get inferenceservice -n kserve -w' if desired."
fi

# Test autoscaling
print_info "Testing Knative autoscaling (scale-to-zero)..."
print_info "Watching pods in kserve namespace for 60 seconds..."
print_info "You should see pods scale down after 5 minutes of inactivity"
kubectl get pods -n kserve -w &
WATCH_PID=$!
sleep 10
kill $WATCH_PID 2>/dev/null || true

# Summary
echo ""
echo "========================================="
echo "Phase 2 Deployment Summary"
echo "========================================="
print_success "✓ Knative Serving CRDs installed"
print_success "✓ Knative Serving Core components running"
print_success "✓ Knative autoscaling configured (scale-to-zero enabled)"
print_success "✓ Knative Istio networking layer installed"
print_success "✓ KServe installed (CRDs + controller)"
print_success "✓ OpenVINO ClusterServingRuntime deployed"
print_success "✓ KServe configured with storage and ingress"
echo ""
print_info "Autoscaling Configuration:"
echo "  Dynamically configured based on node CPU resources"
echo "  Min Replicas: 1 (keeps model always ready)"
echo "  Max Replicas: Auto-detected (based on available CPU cores)"
echo "  Scaling Metrics: Dual (Concurrency + CPU at 70%)"
echo "  Target Concurrency: 10 requests/pod"
echo "  Scale Down Delay: 30 seconds"
echo ""
print_info "Note: Run 'kubectl get inferenceservice -n kserve -o yaml' to see actual configuration"
echo ""
print_info "Next Step: Run Phase 3 to install LiteLLM + Redis + Postgres"
echo "  cd ../phase3-litellm-stack && ./deploy-phase3.sh"
echo ""
