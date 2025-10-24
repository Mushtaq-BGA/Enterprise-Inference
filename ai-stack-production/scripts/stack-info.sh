#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_section() {
    echo -e "\n${CYAN}▶ $1${NC}"
    echo -e "${CYAN}$(printf '─%.0s' {1..60})${NC}"
}

print_item() {
    printf "  %-30s ${GREEN}%s${NC}\n" "$1:" "$2"
}

print_warning() {
    printf "  %-30s ${YELLOW}%s${NC}\n" "$1:" "$2"
}

print_error() {
    printf "  %-30s ${RED}%s${NC}\n" "$1:" "$2"
}

check_command() {
    command -v "$1" &>/dev/null
}

# Main Info Display
print_header "AI Stack Production - System Information"

# ==========================================
# SYSTEM INFO
# ==========================================
print_section "System Information"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    print_item "OS" "$PRETTY_NAME"
fi

print_item "Kernel" "$(uname -r)"
print_item "Architecture" "$(uname -m)"
print_item "Hostname" "$(hostname)"
print_item "Uptime" "$(uptime -p 2>/dev/null || uptime | cut -d',' -f1 | sed 's/.*up //')"

# CPU & Memory
CPUS=$(nproc)
TOTAL_MEM=$(free -h | awk '/^Mem:/ {print $2}')
USED_MEM=$(free -h | awk '/^Mem:/ {print $3}')
print_item "CPU Cores" "$CPUS"
print_item "Memory (Total/Used)" "$TOTAL_MEM / $USED_MEM"

# Disk
DISK_USAGE=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
print_item "Disk Usage (Root)" "$DISK_USAGE"

# ==========================================
# KUBERNETES
# ==========================================
print_section "Kubernetes Cluster"

if check_command kubectl; then
    KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || kubectl version --client --short 2>/dev/null | cut -d' ' -f3)
    print_item "kubectl Version" "$KUBECTL_VERSION"
    
    if kubectl cluster-info &>/dev/null; then
        K8S_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || kubectl version --short 2>/dev/null | grep Server | cut -d' ' -f3)
        print_item "Kubernetes Version" "$K8S_VERSION"
        
        # Node info
        NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        print_item "Nodes" "$NODE_COUNT"
        
        kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory --no-headers 2>/dev/null | while read -r line; do
            NODE_NAME=$(echo "$line" | awk '{print $1}')
            NODE_STATUS=$(echo "$line" | awk '{print $2}')
            NODE_VERSION=$(echo "$line" | awk '{print $3}')
            NODE_CPU=$(echo "$line" | awk '{print $4}')
            NODE_MEM=$(echo "$line" | awk '{print $5}')
            
            if [ "$NODE_STATUS" = "Ready" ]; then
                print_item "  └─ $NODE_NAME" "Ready | v$NODE_VERSION | ${NODE_CPU} CPU, ${NODE_MEM} RAM"
            else
                print_warning "  └─ $NODE_NAME" "$NODE_STATUS | v$NODE_VERSION"
            fi
        done
        
        # Namespaces
        NAMESPACE_COUNT=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l)
        print_item "Namespaces" "$NAMESPACE_COUNT"
    else
        print_error "Cluster" "Not accessible"
    fi
else
    print_error "kubectl" "Not installed"
fi

# ==========================================
# ISTIO
# ==========================================
print_section "Istio Service Mesh (Phase 1)"

# Try to find istioctl in common locations
ISTIOCTL_PATH=""
if check_command istioctl; then
    ISTIOCTL_PATH="istioctl"
elif [ -f "../phase1-cluster-istio/.istio-1.27.3/bin/istioctl" ]; then
    ISTIOCTL_PATH="../phase1-cluster-istio/.istio-1.27.3/bin/istioctl"
elif [ -f "phase1-cluster-istio/.istio-1.27.3/bin/istioctl" ]; then
    ISTIOCTL_PATH="phase1-cluster-istio/.istio-1.27.3/bin/istioctl"
else
    # Try to find any istio directory
    ISTIOCTL_PATH=$(find . -name "istioctl" -type f 2>/dev/null | head -1)
fi

if [ -n "$ISTIOCTL_PATH" ] && [ -x "$ISTIOCTL_PATH" ]; then
    ISTIOCTL_VERSION=$($ISTIOCTL_PATH version --remote=false --short 2>/dev/null | head -1)
    print_item "istioctl Version" "$ISTIOCTL_VERSION"
    
    if kubectl get namespace istio-system &>/dev/null; then
        ISTIO_VERSION=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d':' -f2)
        print_item "Istio Version" "$ISTIO_VERSION"
        
        # Control Plane Status
        ISTIOD_READY=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        ISTIOD_DESIRED=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ "$ISTIOD_READY" = "$ISTIOD_DESIRED" ] && [ "$ISTIOD_READY" -gt 0 ]; then
            print_item "Control Plane (istiod)" "$ISTIOD_READY/$ISTIOD_DESIRED replicas"
        else
            print_warning "Control Plane (istiod)" "$ISTIOD_READY/$ISTIOD_DESIRED replicas"
        fi
        
        # Ingress Gateway
        GATEWAY_READY=$(kubectl get deployment istio-ingressgateway -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        GATEWAY_DESIRED=$(kubectl get deployment istio-ingressgateway -n istio-system -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ "$GATEWAY_READY" = "$GATEWAY_DESIRED" ] && [ "$GATEWAY_READY" -gt 0 ]; then
            print_item "Ingress Gateway" "$GATEWAY_READY/$GATEWAY_DESIRED replicas"
        else
            print_warning "Ingress Gateway" "$GATEWAY_READY/$GATEWAY_DESIRED replicas"
        fi
        
        # Endpoints
        HTTP_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null)
        HTTPS_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null)
        NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        print_item "HTTP Endpoint" "http://$NODE_IP:$HTTP_PORT"
        print_item "HTTPS Endpoint" "https://$NODE_IP:$HTTPS_PORT"
        
        # mTLS Status
        MTLS_MODE=$(kubectl get peerauthentication -n istio-system default -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "Not configured")
        print_item "mTLS Mode" "$MTLS_MODE"
    else
        print_error "Istio" "Not deployed"
    fi
else
    # If istioctl not found, still show Istio info from cluster
    if kubectl get namespace istio-system &>/dev/null; then
        ISTIO_VERSION=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d':' -f2)
        print_item "Istio Version" "$ISTIO_VERSION"
        print_warning "istioctl" "Not found in PATH"
        
        # Control Plane Status
        ISTIOD_READY=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        ISTIOD_DESIRED=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ "$ISTIOD_READY" = "$ISTIOD_DESIRED" ] && [ "$ISTIOD_READY" -gt 0 ]; then
            print_item "Control Plane (istiod)" "$ISTIOD_READY/$ISTIOD_DESIRED replicas"
        else
            print_warning "Control Plane (istiod)" "$ISTIOD_READY/$ISTIOD_DESIRED replicas"
        fi
        
        # Ingress Gateway
        GATEWAY_READY=$(kubectl get deployment istio-ingressgateway -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        GATEWAY_DESIRED=$(kubectl get deployment istio-ingressgateway -n istio-system -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ "$GATEWAY_READY" = "$GATEWAY_DESIRED" ] && [ "$GATEWAY_READY" -gt 0 ]; then
            print_item "Ingress Gateway" "$GATEWAY_READY/$GATEWAY_DESIRED replicas"
        else
            print_warning "Ingress Gateway" "$GATEWAY_READY/$GATEWAY_DESIRED replicas"
        fi
        
        # Endpoints
        HTTP_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null)
        HTTPS_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null)
        NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        print_item "HTTP Endpoint" "http://$NODE_IP:$HTTP_PORT"
        print_item "HTTPS Endpoint" "https://$NODE_IP:$HTTPS_PORT"
        
        # mTLS Status
        MTLS_MODE=$(kubectl get peerauthentication -n istio-system default -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "Not configured")
        print_item "mTLS Mode" "$MTLS_MODE"
    else
        print_error "Istio" "Not deployed"
    fi
fi

# ==========================================
# CERT-MANAGER
# ==========================================
print_section "Cert-Manager (Phase 1.5)"

if kubectl get namespace cert-manager &>/dev/null; then
    CERTMGR_VERSION=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d':' -f2)
    print_item "Cert-Manager Version" "$CERTMGR_VERSION"
    
    CERTMGR_READY=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    CERTMGR_DESIRED=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [ "$CERTMGR_READY" = "$CERTMGR_DESIRED" ] && [ "$CERTMGR_READY" -gt 0 ]; then
        print_item "Status" "$CERTMGR_READY/$CERTMGR_DESIRED replicas"
    else
        print_warning "Status" "$CERTMGR_READY/$CERTMGR_DESIRED replicas"
    fi
    
    # Issuers
    ISSUER_COUNT=$(kubectl get clusterissuer --no-headers 2>/dev/null | wc -l)
    print_item "ClusterIssuers" "$ISSUER_COUNT"
else
    print_warning "Cert-Manager" "Not deployed"
fi

# ==========================================
# KNATIVE
# ==========================================
print_section "Knative Serving (Phase 2)"

if kubectl get namespace knative-serving &>/dev/null; then
    KNATIVE_VERSION=$(kubectl get deployment activator -n knative-serving -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1)
    print_item "Knative Version" "$KNATIVE_VERSION"
    
    # Core components
    for component in activator autoscaler controller webhook; do
        READY=$(kubectl get deployment $component -n knative-serving -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        DESIRED=$(kubectl get deployment $component -n knative-serving -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ "$READY" = "$DESIRED" ] && [ "$READY" -gt 0 ]; then
            print_item "  └─ $component" "$READY/$DESIRED"
        else
            print_warning "  └─ $component" "$READY/$DESIRED"
        fi
    done
else
    print_warning "Knative" "Not deployed"
fi

# ==========================================
# KSERVE
# ==========================================
print_section "KServe Model Serving (Phase 2)"

if kubectl get namespace kserve &>/dev/null; then
    KSERVE_VERSION=$(kubectl get deployment kserve-controller-manager -n kserve -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+')
    print_item "KServe Version" "$KSERVE_VERSION"
    
    KSERVE_READY=$(kubectl get deployment kserve-controller-manager -n kserve -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    KSERVE_DESIRED=$(kubectl get deployment kserve-controller-manager -n kserve -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [ "$KSERVE_READY" = "$KSERVE_DESIRED" ] && [ "$KSERVE_READY" -gt 0 ]; then
        print_item "Controller" "$KSERVE_READY/$KSERVE_DESIRED replicas"
    else
        print_warning "Controller" "$KSERVE_READY/$KSERVE_DESIRED replicas"
    fi
    
    # InferenceServices
    ISVC_COUNT=$(kubectl get inferenceservice -A --no-headers 2>/dev/null | wc -l)
    ISVC_READY=$(kubectl get inferenceservice -A --no-headers 2>/dev/null | grep -c "True" || echo "0")
    print_item "InferenceServices" "$ISVC_READY/$ISVC_COUNT ready"
    
    # List models
    if [ "$ISVC_COUNT" -gt 0 ]; then
        kubectl get inferenceservice -A --no-headers 2>/dev/null | while read -r ns name url ready rest; do
            if [ "$ready" = "True" ]; then
                print_item "  └─ $name" "Ready"
            else
                print_warning "  └─ $name" "$ready"
            fi
        done
    fi
    
    # Runtimes
    RUNTIME_COUNT=$(kubectl get clusterservingruntime --no-headers 2>/dev/null | wc -l)
    print_item "Serving Runtimes" "$RUNTIME_COUNT"
else
    print_warning "KServe" "Not deployed"
fi

# ==========================================
# LITELLM
# ==========================================
print_section "LiteLLM API Gateway (Phase 3)"

if kubectl get namespace litellm &>/dev/null; then
    LITELLM_VERSION=$(kubectl get deployment litellm -n litellm -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d':' -f2)
    print_item "LiteLLM Version" "$LITELLM_VERSION"
    
    # LiteLLM replicas
    LITELLM_READY=$(kubectl get deployment litellm -n litellm -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    LITELLM_DESIRED=$(kubectl get deployment litellm -n litellm -o jsonpath='{.spec.replicas}' 2>/dev/null)
    print_item "Replicas" "$LITELLM_READY/$LITELLM_DESIRED"
    
    # HPA
    HPA_MIN=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
    HPA_MAX=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
    HPA_CURRENT=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.status.currentReplicas}' 2>/dev/null)
    if [ -n "$HPA_MIN" ]; then
        print_item "HPA (min/current/max)" "$HPA_MIN / $HPA_CURRENT / $HPA_MAX"
    fi
    
    # API Key
    API_KEY=$(kubectl get secret litellm-config -n litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || kubectl get deployment litellm -n litellm -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}' 2>/dev/null)
    if [ -n "$API_KEY" ]; then
        print_item "API Key" "${API_KEY:0:20}..."
    fi
    
    # PostgreSQL
    if kubectl get namespace postgres &>/dev/null; then
        PG_READY=$(kubectl get statefulset postgres -n postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        PG_DESIRED=$(kubectl get statefulset postgres -n postgres -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ "$PG_READY" = "$PG_DESIRED" ] && [ "$PG_READY" -gt 0 ]; then
            print_item "PostgreSQL" "$PG_READY/$PG_DESIRED replicas"
        else
            print_warning "PostgreSQL" "$PG_READY/$PG_DESIRED replicas"
        fi
    fi
    
    # Redis
    if kubectl get namespace redis &>/dev/null; then
        REDIS_READY=$(kubectl get deployment redis -n redis -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        REDIS_DESIRED=$(kubectl get deployment redis -n redis -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ "$REDIS_READY" = "$REDIS_DESIRED" ] && [ "$REDIS_READY" -gt 0 ]; then
            print_item "Redis Cache" "$REDIS_READY/$REDIS_DESIRED replicas"
        else
            print_warning "Redis Cache" "$REDIS_READY/$REDIS_DESIRED replicas"
        fi
    fi
else
    print_warning "LiteLLM" "Not deployed"
fi

# ==========================================
# MODEL WATCHER
# ==========================================
print_section "Model Watcher (Phase 4)"

if kubectl get namespace model-watcher &>/dev/null; then
    WATCHER_READY=$(kubectl get deployment model-watcher -n model-watcher -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    WATCHER_DESIRED=$(kubectl get deployment model-watcher -n model-watcher -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [ "$WATCHER_READY" = "$WATCHER_DESIRED" ] && [ "$WATCHER_READY" -gt 0 ]; then
        print_item "Status" "$WATCHER_READY/$WATCHER_DESIRED replicas"
    else
        print_warning "Status" "$WATCHER_READY/$WATCHER_DESIRED replicas"
    fi
    
    # Check recent activity
    LAST_SYNC=$(kubectl logs -n model-watcher deployment/model-watcher --tail=100 2>/dev/null | grep -i "sync\|registered" | tail -1 | cut -d' ' -f1-2)
    if [ -n "$LAST_SYNC" ]; then
        print_item "Last Activity" "$LAST_SYNC"
    fi
else
    print_warning "Model Watcher" "Not deployed"
fi

# ==========================================
# TOOLS & UTILITIES
# ==========================================
print_section "Installed Tools"

check_and_print_version() {
    local tool=$1
    local version_cmd=$2
    
    if check_command "$tool"; then
        local version=$(eval "$version_cmd" 2>/dev/null | head -1)
        if [ -n "$version" ]; then
            print_item "$tool" "$version"
        else
            print_warning "$tool" "Installed but version unknown"
        fi
    else
        print_warning "$tool" "Not installed"
    fi
}

# Container runtime
check_and_print_version "containerd" "containerd --version 2>&1 | head -1 | awk '{print \$3}'"
check_and_print_version "crictl" "crictl --version 2>&1 | awk '{print \$3}'"

# Package managers
check_and_print_version "helm" "helm version --short 2>&1 | cut -d':' -f2 | tr -d ' '"

# Development tools
check_and_print_version "jq" "jq --version 2>&1 | cut -d'-' -f2"
check_and_print_version "git" "git --version 2>&1 | awk '{print \$3}'"
check_and_print_version "python3" "python3 --version 2>&1 | awk '{print \$2}'"
check_and_print_version "wrk" "wrk --version 2>&1 | head -1 | awk '{print \$2}'"

# ==========================================
# RESOURCE USAGE
# ==========================================
print_section "Cluster Resource Usage"

if kubectl cluster-info &>/dev/null; then
    # Total pods
    TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
    RUNNING_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    print_item "Pods (Running/Total)" "$RUNNING_PODS / $TOTAL_PODS"
    
    # Pods by namespace
    echo ""
    printf "  ${CYAN}Top Namespaces by Pod Count:${NC}\n"
    kubectl get pods -A --no-headers 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -5 | while read -r count ns; do
        printf "    %-25s %s\n" "$ns" "$count pods"
    done
    
    # Top CPU/Memory consumers (if metrics-server is available)
    if kubectl top nodes &>/dev/null 2>&1; then
        echo ""
        printf "  ${CYAN}Node Metrics:${NC}\n"
        kubectl top nodes --no-headers 2>/dev/null | while read -r line; do
            NODE=$(echo "$line" | awk '{print $1}')
            CPU=$(echo "$line" | awk '{print $2}')
            MEM=$(echo "$line" | awk '{print $4}')
            printf "    %-25s CPU: %s, Memory: %s\n" "$NODE" "$CPU" "$MEM"
        done
    fi
fi

# ==========================================
# ENDPOINTS SUMMARY
# ==========================================
print_section "Access Endpoints"

if kubectl get svc istio-ingressgateway -n istio-system &>/dev/null; then
    HTTP_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null)
    HTTPS_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null)
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    
    print_item "LiteLLM HTTP" "http://litellm.aistack.local:$HTTP_PORT"
    print_item "LiteLLM HTTPS" "https://litellm.aistack.local:$HTTPS_PORT"
    print_item "Node IP" "$NODE_IP"
    
    echo ""
    echo -e "  ${YELLOW}Note: Add to /etc/hosts:${NC}"
    echo -e "  ${YELLOW}echo \"$NODE_IP litellm.aistack.local\" | sudo tee -a /etc/hosts${NC}"
fi

# ==========================================
# FOOTER
# ==========================================
echo ""
print_header "End of System Information"
echo ""
echo -e "${CYAN}For HTTPS setup, run:${NC} ./scripts/setup-local-https.sh"
echo -e "${CYAN}For security check, run:${NC} ./scripts/verify-istio-security.sh"
echo -e "${CYAN}For load testing, run:${NC} cd phase5-optimization && ./load-test-baseline.sh"
echo ""
