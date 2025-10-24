#!/bin/bash
# Master deployment script for AI Stack
# Orchestrates all 5 phases with validation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root is parent of scripts directory
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Phases live at repository root (phase0-kubernetes-cluster, phase1-cluster-istio, etc.)
PHASES_DIR="$PROJECT_ROOT"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="$PROJECT_ROOT/deployment-$(date +%Y%m%d-%H%M%S).log"

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

print_success() {
    log "${GREEN}✓ $1${NC}"
}

print_error() {
    log "${RED}✗ $1${NC}"
}

print_info() {
    log "${YELLOW}ℹ $1${NC}"
}

print_header() {
    log "${BLUE}"
    log "========================================="
    log "$1"
    log "========================================="
    log "${NC}"
}

# Error handler
error_exit() {
    print_error "Deployment failed at: $1"
    print_info "Check log file: $LOG_FILE"
    exit 1
}

trap 'error_exit "$BASH_COMMAND"' ERR

# Parse arguments
SKIP_PHASES=()
DRY_RUN=false
INSTALL_KUBERNETES=false
K8S_MODE="single-node"  # single-node or multi-node
AUTO_CONTINUE=false
K8S_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --install-k8s)
            INSTALL_KUBERNETES=true
            shift
            ;;
        --k8s-only)
            INSTALL_KUBERNETES=true
            K8S_ONLY=true
            shift
            ;;
        --k8s-mode)
            K8S_MODE="$2"
            shift 2
            ;;
        --skip-phase)
            SKIP_PHASES+=("$2")
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --auto-continue)
            AUTO_CONTINUE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "DEPLOYMENT MODES:"
            echo ""
            echo "  Mode 1: Deploy on Existing Kubernetes Cluster (default)"
            echo "    $0"
            echo ""
            echo "  Mode 2: Fresh Installation (includes Kubernetes)"
            echo "    $0 --install-k8s [--k8s-mode single-node|multi-node]"
            echo ""
            echo "  Mode 3: Install Kubernetes Only (no AI stack)"
            echo "    $0 --k8s-only [--k8s-mode single-node|multi-node]"
            echo ""
            echo "Options:"
            echo "  --install-k8s        Install Kubernetes first (Phase 0)"
            echo "  --k8s-only           Install Kubernetes only and exit (no AI stack)"
            echo "  --k8s-mode MODE      Kubernetes mode: single-node or multi-node (default: single-node)"
            echo "  --skip-phase N       Skip phase N (can be specified multiple times)"
            echo "  --dry-run            Show what would be deployed without executing"
            echo "  --auto-continue      Do not prompt between phases; run sequentially"
            echo "  --help               Show this help message"
            echo ""
            echo "Deployment Phases:"
            echo "  Phase 0: Kubernetes Cluster (optional, use --install-k8s)"
            echo "  Phase 1: Base Cluster + Istio + Namespaces"
                        echo "  Phase 1.5: Cert-Manager + Issuers"
            echo "  Phase 2: Knative + KServe + Autoscaling"
            echo "  Phase 3: LiteLLM + Redis + Postgres"
            echo "  Phase 4: Model Watcher (Auto-registration)"
            echo ""
            echo "Note: Phase 5 (optimization) is optional and can be run separately"
            echo "      from the phase5-optimization directory."
            echo ""
            echo "Examples:"
            echo ""
            echo "  # Deploy on existing cluster (default)"
            echo "  $0"
            echo ""
            echo "  # Fresh installation with single-node Kubernetes"
            echo "  $0 --install-k8s"
            echo ""
            echo "  # Fresh installation with multi-node Kubernetes"
            echo "  $0 --install-k8s --k8s-mode multi-node"
            echo ""
            echo "  # Install Kubernetes only (no AI stack)"
            echo "  $0 --k8s-only"
            echo ""
            echo "  # Install multi-node Kubernetes only"
            echo "  $0 --k8s-only --k8s-mode multi-node"
            echo ""
            echo "  # Skip Phase 1 (if Istio already installed)"
            echo "  $0 --skip-phase 1"
            echo ""
            echo "  # Skip Phase 1.5 (if cert-manager already installed)"
            echo "  $0 --skip-phase 1.5"
            echo ""
            echo "  # Install Kubernetes and skip Phase 1"
            echo "  $0 --install-k8s --skip-phase 1"
            echo ""
            echo "  # Dry run to see what would be deployed"
            echo "  $0 --dry-run"
            echo ""
            echo "  # Dry run with Kubernetes installation"
            echo "  $0 --install-k8s --dry-run"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Start deployment
print_header "AI Stack Production Deployment"
log "Start Time: $(date)"
log "Log File: $LOG_FILE"
echo ""

if [ "$K8S_ONLY" = true ]; then
    print_info "Mode: Kubernetes Installation Only (no AI stack)"
    print_info "Kubernetes Mode: $K8S_MODE"
elif [ "$INSTALL_KUBERNETES" = true ]; then
    print_info "Mode: Fresh Installation (includes Kubernetes)"
    print_info "Kubernetes Mode: $K8S_MODE"
else
    print_info "Mode: Deploy on Existing Kubernetes Cluster"
    print_info "NOTE: To install Kubernetes first, use: $0 --install-k8s"
fi
echo ""

# Phase 0: Install Kubernetes (optional)
if [ "$INSTALL_KUBERNETES" = true ]; then
    print_header "Phase 0: Kubernetes Cluster Installation"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "Would install Kubernetes ($K8S_MODE mode)"
    else
    # Phase 0 manifests directory at repo root
    PHASE0_DIR="$PROJECT_ROOT/phase0-kubernetes-cluster"
        
        if [ ! -d "$PHASE0_DIR" ]; then
            error_exit "Phase 0 directory not found: $PHASE0_DIR"
        fi
        
        if [ "$K8S_MODE" = "multi-node" ]; then
            if [ ! -f "$PHASE0_DIR/deploy-multi-node.sh" ]; then
                error_exit "Multi-node deployment script not found"
            fi
            
            # Check if inventory.ini exists
            if [ ! -f "$PHASE0_DIR/inventory.ini" ]; then
                print_error "inventory.ini not found for multi-node deployment"
                print_info "Please create inventory.ini from inventory.ini.template"
                print_info "Example: cp $PHASE0_DIR/inventory.ini.template $PHASE0_DIR/inventory.ini"
                exit 1
            fi
            
            print_info "Deploying multi-node Kubernetes cluster..."
            chmod +x "$PHASE0_DIR/deploy-multi-node.sh"
            if bash "$PHASE0_DIR/deploy-multi-node.sh" 2>&1 | tee -a "$LOG_FILE"; then
                print_success "Phase 0 (Multi-Node) completed successfully"
            else
                error_exit "Phase 0 (Multi-Node) failed"
            fi
        else
            # Single-node deployment
            if [ ! -f "$PHASE0_DIR/deploy-single-node.sh" ]; then
                error_exit "Single-node deployment script not found"
            fi
            
            print_info "Deploying single-node Kubernetes cluster..."
            chmod +x "$PHASE0_DIR/deploy-single-node.sh"
            if bash "$PHASE0_DIR/deploy-single-node.sh" 2>&1 | tee -a "$LOG_FILE"; then
                print_success "Phase 0 (Single-Node) completed successfully"
            else
                error_exit "Phase 0 (Single-Node) failed"
            fi
        fi
        
        # Verify cluster after installation
        print_info "Verifying Kubernetes cluster..."
        if [ -f "$PHASE0_DIR/verify-cluster.sh" ]; then
            chmod +x "$PHASE0_DIR/verify-cluster.sh"
            bash "$PHASE0_DIR/verify-cluster.sh" 2>&1 | tee -a "$LOG_FILE"
        fi
        
        # Exit if K8s-only mode
        if [ "$K8S_ONLY" = true ]; then
            echo ""
            print_header "Kubernetes Installation Complete!"
            log "End Time: $(date)"
            echo ""
            print_success "Kubernetes cluster installed successfully!"
            echo ""
            echo "========================================="
            echo "Cluster Information"
            echo "========================================="
            kubectl cluster-info
            echo ""
            echo "Nodes:"
            kubectl get nodes -o wide
            echo ""
            echo "========================================="
            echo "Next Steps"
            echo "========================================="
            echo "1. Deploy AI stack on this cluster:"
            echo "   $0"
            echo ""
            echo "2. Or customize deployment with skip options:"
            echo "   $0 --skip-phase 1"
            echo ""
            print_info "Deployment log saved to: $LOG_FILE"
            echo ""
            exit 0
        fi
        
        echo ""
        print_info "Kubernetes installation complete. Proceeding to AI Stack deployment..."
        echo ""
        sleep 5
    fi
fi

# Function to install Helm
install_helm() {
    print_header "Installing Helm Package Manager"
    
    if command -v helm &> /dev/null; then
        HELM_VERSION=$(helm version --short 2>/dev/null | cut -d':' -f2 | tr -d ' ' || echo "unknown")
        print_success "Helm already installed: $HELM_VERSION"
        return 0
    fi
    
    print_info "Helm not found. Installing Helm..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "Would install Helm"
        return 0
    fi
    
    # Download and install Helm
    print_info "Downloading Helm installer..."
    if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get_helm.sh; then
        print_success "Helm installer downloaded"
    else
        error_exit "Failed to download Helm installer"
    fi
    
    print_info "Installing Helm..."
    if chmod 700 /tmp/get_helm.sh && /tmp/get_helm.sh; then
        HELM_VERSION=$(helm version --short 2>/dev/null | cut -d':' -f2 | tr -d ' ' || echo "unknown")
        print_success "Helm installed successfully: $HELM_VERSION"
        rm -f /tmp/get_helm.sh
    else
        error_exit "Failed to install Helm"
    fi
}

# Install Helm if not already installed
install_helm
echo ""

# Pre-flight checks
print_info "Running pre-flight checks..."

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    error_exit "kubectl not found. Please install kubectl."
fi
print_success "kubectl found"

# Check cluster access
if ! kubectl cluster-info &> /dev/null; then
    error_exit "Cannot access Kubernetes cluster. Check your kubeconfig."
fi
print_success "Kubernetes cluster accessible"

# Get cluster info
K8S_VERSION=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}' || echo "unknown")
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
print_info "Kubernetes version: $K8S_VERSION"
print_info "Node count: $NODE_COUNT"

if [ "$DRY_RUN" = true ]; then
    print_info "DRY RUN MODE - No changes will be applied"
    echo ""
fi

echo ""

# Function to deploy a phase
deploy_phase() {
    local phase_num=$1
    local phase_name=$2
    local phase_dir=$3  # e.g. phase1-cluster-istio
    local full_dir="$PHASES_DIR/$phase_dir"
    
    # Check if phase should be skipped
    for skip in "${SKIP_PHASES[@]}"; do
        if [ "$skip" == "$phase_num" ]; then
            print_info "Skipping Phase $phase_num (--skip-phase $phase_num)"
            return 0
        fi
    done
    
    print_header "Phase $phase_num: $phase_name"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "Would deploy: $phase_dir"
        return 0
    fi
    
    # Check if deploy script exists
    if [ ! -f "$full_dir/deploy-phase${phase_num}.sh" ]; then
        print_error "Deploy script not found: $full_dir/deploy-phase${phase_num}.sh"
        return 1
    fi
    
    # Make script executable
    chmod +x "$full_dir/deploy-phase${phase_num}.sh"
    
    # Execute deployment (temporarily disable error trap for better control)
    set +e
    if bash "$full_dir/deploy-phase${phase_num}.sh" 2>&1 | tee -a "$LOG_FILE"; then
        PHASE_EXIT_CODE=0
    else
        PHASE_EXIT_CODE=$?
    fi
    set -e
    
    if [ $PHASE_EXIT_CODE -eq 0 ]; then
        print_success "Phase $phase_num completed successfully"
        echo ""
        
        # Wait for user confirmation (skip for last phase)
        if [[ "$phase_num" =~ ^[0-9]+$ ]] && [ "$phase_num" -lt 4 ] && [ "$AUTO_CONTINUE" = false ]; then
            read -p "Continue to next phase? (y/n): " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Deployment paused. Resume by re-running and skipping completed phases: e.g. --skip-phase $(seq -s ' --skip-phase ' 1 $phase_num)"
                exit 0
            fi
        fi
        
        return 0
    else
        print_error "Phase $phase_num failed with exit code $PHASE_EXIT_CODE"
        print_info "Check the output above for errors"
        return 1
    fi
}

# Deploy phases
# Deploy phases including optional 1.5 Cert-Manager
deploy_phase 1 "Base Cluster + Istio + Namespaces" "phase1-cluster-istio"
deploy_phase 1.5 "Cert-Manager + Issuers" "phase1.5-cert-manager"
deploy_phase 2 "Knative + KServe + Autoscaling" "phase2-knative-kserve"
deploy_phase 3 "LiteLLM + Redis + Postgres" "phase3-litellm-stack"
deploy_phase 4 "Model Watcher (Auto-registration)" "phase4-model-watcher"

# AI Stack Deployment Complete
print_header "🎉 AI Stack Deployment Complete! 🎉"
log "End Time: $(date)"
echo ""

# Get access information
HTTP_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null || echo "N/A")
HTTPS_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "N/A")
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")

# Get the actual LiteLLM master key from the deployment
LITELLM_MASTER_KEY=$(kubectl get deployment litellm -n litellm -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}' 2>/dev/null || echo "sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef")

echo "========================================="
echo "🚀 PRODUCTION AI STACK READY!"
echo "========================================="
echo ""
print_success "✅ All core phases (1-4) deployed successfully!"
echo ""
echo "📦 Deployed Components:"
echo "  Phase 1: ✅ Kubernetes + Istio + Security"
echo "  Phase 1.5: ✅ Cert-Manager + TLS"
echo "  Phase 2: ✅ Knative + KServe + Autoscaling"
echo "  Phase 3: ✅ LiteLLM + Redis + PostgreSQL"
echo "  Phase 4: ✅ Model Auto-Registration"
echo ""
echo "========================================="
echo "🌐 Access Information"
echo "========================================="
echo "Istio Ingress Gateway:"
echo "  HTTP:  http://$NODE_IP:$HTTP_PORT"
echo "  HTTPS: https://$NODE_IP:$HTTPS_PORT"
echo ""
echo "LiteLLM API Endpoint:"
echo "  URL: http://litellm.aistack.local:$HTTP_PORT"
echo "  Master Key: $LITELLM_MASTER_KEY"
echo ""
echo "📝 Add to /etc/hosts:"
echo "  echo '$NODE_IP litellm.aistack.local' | sudo tee -a /etc/hosts"
echo ""
echo "========================================="
echo "🧪 Test Your AI Stack"
echo "========================================="
echo ""
echo "Available Testing Scripts in ./scripts/ directory:"
echo ""
echo "🔍 1. Stack Information & Health:"
echo "   ./stack-info.sh                 # Complete system overview"
echo ""
echo "📊 2. Model Benchmarking:"
echo "   ./benchmark_model.py            # Python benchmarking tool"
echo "   cat BENCHMARK_README.md         # Benchmarking documentation"
echo ""
echo "🔧 3. LiteLLM Model Management:"
echo "   ./litellm-model-helper.sh       # Add/remove models from LiteLLM"
echo ""
echo "🔒 4. Security Verification:"
echo "   ./verify-istio-security.sh      # Verify mTLS and security policies"
echo ""
echo "🌐 5. HTTPS Setup (Optional):"
echo "   ./setup-local-https.sh          # Configure local HTTPS"
echo "   cat HTTPS_SETUP_README.md       # HTTPS setup guide"
echo ""
echo "========================================="
echo "🚀 Quick Health Tests"
echo "========================================="
echo "1. Basic health check:"
echo "   curl http://litellm.aistack.local:$HTTP_PORT/health/readiness"
echo ""
echo "2. Authenticated health check:"
echo "   curl http://litellm.aistack.local:$HTTP_PORT/health \\"
echo "     -H 'Authorization: Bearer $LITELLM_MASTER_KEY'"
echo ""
echo "3. List available models:"
echo "   curl http://litellm.aistack.local:$HTTP_PORT/v1/models \\"
echo "     -H 'Authorization: Bearer $LITELLM_MASTER_KEY'"
echo ""
echo "4. Test model inference:"
echo "   curl -X POST http://litellm.aistack.local:$HTTP_PORT/v1/chat/completions \\"
echo "     -H 'Authorization: Bearer $LITELLM_MASTER_KEY' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"model\":\"qwen3-4b-int4-ov\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello! How are you?\"}]}'"
echo ""
echo "========================================="
echo "📚 Additional Resources"
echo "========================================="
echo "• Sample InferenceService: ../phase2-knative-kserve/90-sample-inferenceservice.yaml"
echo "• Load Testing Scripts: ../phase5-optimization/"
echo "• Documentation: ../docs/"
echo "• Troubleshooting: kubectl get pods --all-namespaces"
echo ""
echo "🎯 Your AI Stack is ready for production workloads!"
echo ""
print_info "Deployment log saved to: $LOG_FILE"
echo ""
