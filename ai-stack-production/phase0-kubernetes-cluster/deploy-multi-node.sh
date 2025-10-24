#!/bin/bash
# Phase 0: Deploy Multi-Node Kubernetes Cluster with Kubespray
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBESPRAY_DIR="$PROJECT_ROOT/kubespray"

echo "========================================="
echo "Phase 0: Kubernetes Multi-Node Setup"
echo "========================================="
echo ""

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

# Check if inventory file exists
if [ ! -f "$SCRIPT_DIR/inventory.ini" ]; then
    print_error "inventory.ini not found!"
    echo ""
    echo "Please create inventory.ini with your node IPs:"
    echo ""
    cat "$SCRIPT_DIR/inventory.ini.template"
    echo ""
    echo "Copy the template and edit:"
    echo "  cp inventory.ini.template inventory.ini"
    echo "  vi inventory.ini"
    exit 1
fi

print_info "Using inventory file: $SCRIPT_DIR/inventory.ini"

# Check prerequisites
print_info "Checking prerequisites..."

# Check Python
if ! command -v python3 &> /dev/null; then
    print_error "Python 3 not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip
fi
print_success "Python 3 found"

# Install dependencies
print_info "Installing dependencies..."
sudo apt-get update
sudo apt-get install -y git python3 python3-pip python3-venv sshpass

# Clone Kubespray if not exists
if [ ! -d "$KUBESPRAY_DIR" ]; then
    print_info "Cloning Kubespray into project root..."
    cd "$PROJECT_ROOT"
    git clone https://github.com/kubernetes-sigs/kubespray.git "$(basename "$KUBESPRAY_DIR")"
    cd "$KUBESPRAY_DIR"
    git checkout v2.28.1  # Kubespray v2.28.1 for Kubernetes v1.32.8
else
    print_info "Kubespray already cloned at $KUBESPRAY_DIR"
    cd "$KUBESPRAY_DIR"
fi

# Create Python virtual environment (required for Ubuntu 24.04+)
VENV_DIR="$KUBESPRAY_DIR/.kubespray-venv"
if [ ! -d "$VENV_DIR" ]; then
    print_info "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    print_success "Virtual environment created"
else
    print_info "Using existing virtual environment"
fi

# Activate virtual environment
print_info "Activating virtual environment..."
source "$VENV_DIR/bin/activate"

# Install Python requirements
print_info "Installing Python requirements in venv..."
pip install --upgrade pip
pip install -r requirements.txt

# Parse inventory and build Kubespray inventory
print_info "Building Kubespray inventory from inventory.ini..."

# Extract IPs from inventory.ini
IPS=($(grep -v '^#' "$SCRIPT_DIR/inventory.ini" | grep -v '^\[' | grep -oP '\d+\.\d+\.\d+\.\d+' || true))

if [ ${#IPS[@]} -eq 0 ]; then
    print_error "No IP addresses found in inventory.ini"
    exit 1
fi

print_info "Found ${#IPS[@]} nodes: ${IPS[*]}"

# Build inventory using Kubespray inventory builder
CONFIG_FILE=inventory/mycluster/hosts.yaml python3 contrib/inventory_builder/inventory.py ${IPS[@]}

# Configure cluster settings
print_info "Configuring cluster settings for HA multi-node..."

cat > inventory/mycluster/group_vars/k8s_cluster.yml <<EOF
# Kubernetes cluster name
cluster_name: ai-stack-cluster

# Kubernetes version
kube_version: v1.32.8

# Container runtime
container_manager: containerd

# Network plugin
kube_network_plugin: calico
kube_network_plugin_multus: false

# DNS
dns_mode: coredns
enable_nodelocaldns: true

# Service CIDR
kube_service_addresses: 10.233.0.0/18

# Pod CIDR
kube_pods_subnet: 10.233.64.0/18

# Proxy mode
kube_proxy_mode: ipvs

# Enable metrics
metrics_server_enabled: true

# Storage
local_path_provisioner_enabled: true
local_path_provisioner_is_default_storageclass: true

# HA settings
etcd_deployment_type: host
etcd_events_cluster_enabled: true

# API server settings
kube_apiserver_enable_admission_plugins:
  - NodeRestriction
  - PodSecurityPolicy

# Feature gates
kube_feature_gates:
  - TTLAfterFinished=true
  - RotateKubeletServerCertificate=true

# Hardening
podsecuritypolicy_enabled: false
EOF

print_success "Configuration complete"

# Test SSH connectivity
print_info "Testing SSH connectivity to all nodes..."
for ip in "${IPS[@]}"; do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$ip" "echo 'OK'" &> /dev/null; then
        print_success "SSH to $ip: OK"
    else
        print_error "SSH to $ip: FAILED"
        echo "Please ensure SSH key-based authentication is set up for all nodes"
        exit 1
    fi
done

# Deploy cluster
print_info "Deploying Kubernetes cluster (this takes 15-20 minutes)..."
print_info "Follow progress in another terminal: tail -f /tmp/kubespray-install.log"

ansible-playbook -i inventory/mycluster/hosts.yaml \
  --become --become-user=root \
  cluster.yml 2>&1 | tee /tmp/kubespray-install.log

# Get kubeconfig from first control plane node
FIRST_MASTER=${IPS[0]}
print_info "Getting kubeconfig from $FIRST_MASTER..."
mkdir -p $HOME/.kube
scp $FIRST_MASTER:/etc/kubernetes/admin.conf $HOME/.kube/config
chmod 600 $HOME/.kube/config

# Wait for cluster to be ready
print_info "Waiting for cluster to be ready..."
sleep 30

# Verify installation
print_info "Verifying installation..."
kubectl cluster-info
kubectl get nodes

# Wait for all system pods
print_info "Waiting for system pods to be ready..."
kubectl wait --for=condition=ready pod --all -n kube-system --timeout=600s || true

# Summary
echo ""
echo "========================================="
echo "Phase 0 Deployment Summary"
echo "========================================="
print_success "✓ Multi-node Kubernetes cluster installed"
print_success "✓ Nodes: ${#IPS[@]}"
print_success "✓ Container runtime: containerd"
print_success "✓ Network plugin: Calico"
print_success "✓ DNS: CoreDNS + NodeLocalDNS"
print_success "✓ Storage: local-path-provisioner"
print_success "✓ Metrics: metrics-server"
print_success "✓ kubectl configured"
echo ""

# Show cluster info
print_info "Cluster Information:"
kubectl get nodes -o wide
echo ""
kubectl get pods --all-namespaces

echo ""
print_info "Run verification script to ensure everything is working:"
echo "  ./verify-cluster.sh"
echo ""
print_info "Next Step: Deploy Istio and AI Stack components"
echo "  cd ../phase1-cluster-istio && ./deploy-phase1.sh"
echo ""
