#!/bin/bash
# Phase 4: LiteLLM Model Registration (Kubernetes Job version)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
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

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "Missing required command: $1"
        exit 1
    fi
}

# Detect cluster domain from CoreDNS
detect_cluster_domain() {
    local corefile
    corefile=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
    if [ -z "$corefile" ]; then
        echo "cluster.local"
        return
    fi
    
    local domain
    domain=$(printf '%s\n' "$corefile" | awk '/^\s*kubernetes /{print $2; exit}')
    echo "${domain:-cluster.local}"
}

echo "========================================="
echo "Phase 4: LiteLLM Model Registration"
echo "========================================="

require_command kubectl

# Configuration
CLUSTER_DOMAIN=$(detect_cluster_domain)
KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-kserve}"
LITELLM_NAMESPACE="${LITELLM_NAMESPACE:-litellm}"
ACTION="${1:-register}"

print_info "Detected cluster domain: $CLUSTER_DOMAIN"
print_info "KServe namespace: $KSERVE_NAMESPACE"
print_info "LiteLLM namespace: $LITELLM_NAMESPACE"

# Clean up legacy resources if they exist
print_info "Cleaning up legacy Kubernetes watcher resources (if present)..."
kubectl delete deployment model-watcher -n model-watcher --ignore-not-found 2>/dev/null || true
kubectl delete job model-registration -n default --ignore-not-found 2>/dev/null || true

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

# Create ConfigMap with the Python script
print_info "Creating model registration script ConfigMap..."
kubectl create configmap model-registration-script -n default \
    --from-file=manage-litellm-models.py="$SCRIPT_DIR/manage-litellm-models.py" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create RBAC for the Job
print_info "Creating ServiceAccount and RBAC..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: model-registration
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: model-registration-role
rules:
- apiGroups: ["serving.kserve.io"]
  resources: ["inferenceservices"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: model-registration-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: model-registration-role
subjects:
- kind: ServiceAccount
  name: model-registration
  namespace: default
EOF

# Create the Job
print_info "Creating model registration Job..."
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: model-registration
  namespace: default
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 2
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      serviceAccountName: model-registration
      containers:
      - name: register
        image: python:3.12-slim
        command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "Installing kubectl..."
          apt-get update -qq && apt-get install -y -qq curl > /dev/null
          curl -sLO "https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl"
          chmod +x kubectl && mv kubectl /usr/local/bin/
          
          echo "Running model registration..."
          python3 /scripts/manage-litellm-models.py \\
            $ACTION \\
            --litellm-url http://litellm.${LITELLM_NAMESPACE}.svc.${CLUSTER_DOMAIN}:4000 \\
            --api-key sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef \\
            --kserve-namespace ${KSERVE_NAMESPACE} \\
            --kubectl kubectl
          
          echo "Model registration complete!"
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
      volumes:
      - name: scripts
        configMap:
          name: model-registration-script
EOF

print_success "Model registration Job created"
print_info "Waiting for Job to complete..."

# Wait for Job to complete
if kubectl wait --for=condition=complete --timeout=120s job/model-registration -n default 2>/dev/null; then
    print_success "Model registration completed successfully"
    echo ""
    print_info "Job logs:"
    kubectl logs job/model-registration -n default
    echo ""
else
    print_error "Model registration Job failed or timed out"
    echo ""
    print_info "Job logs:"
    kubectl logs job/model-registration -n default || true
    echo ""
    print_info "Job status:"
    kubectl get job model-registration -n default
    exit 1
fi

# Show registered models
echo ""
echo "========================================="
echo "Registered Models"
echo "========================================="
kubectl run show-models --image=curlimages/curl:latest --rm -i --restart=Never --command -- \
    curl -s http://litellm.${LITELLM_NAMESPACE}.svc.${CLUSTER_DOMAIN}:4000/v1/models \
    -H "Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef" || true

echo ""
print_success "Phase 4 complete!"
