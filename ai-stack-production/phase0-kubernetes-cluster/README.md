# Phase 0: Kubernetes Cluster Setup with Kubespray

This phase sets up a Kubernetes cluster using Kubespray. Choose between:
- **Single-node cluster** (for development/testing)
- **Multi-node cluster** (for production)

## Prerequisites

- Ubuntu 20.04+ or similar Linux distribution (Ubuntu 24.04 supported with automatic venv)
- Root or sudo access
- Minimum 4 CPU cores, 16GB RAM (single-node)
- Python 3.8+
- SSH access to all nodes

**Note for Ubuntu 24.04+**: Python virtual environments are automatically created to comply with PEP 668 externally-managed environment restrictions.

## Quick Start

### Option 1: Single Node (Development)

```bash
cd /home/ubuntu/ai-stack-production/phase0-kubernetes-cluster
./deploy-single-node.sh
```

### Option 2: Multi-Node (Production)

```bash
cd /home/ubuntu/ai-stack-production/phase0-kubernetes-cluster

# 1. Edit inventory
vi inventory.ini
# Add your node IPs and SSH details

# 2. Deploy cluster
./deploy-multi-node.sh
```

## What Gets Installed

- **Kubespray**: v2.28.1
- **Kubernetes**: v1.32.8 (latest stable)
- **Container Runtime**: containerd
- **Network Plugin**: Calico
- **DNS**: CoreDNS
- **Storage**: local-path-provisioner
- **Metrics**: metrics-server

## Kubespray Configuration

Our setup uses optimized Kubespray settings:

### Single-Node Mode
- Kubernetes master + worker on same node
- No HA (single control plane)
- Local storage with local-path-provisioner
- Suitable for: dev, testing, small deployments

### Multi-Node Mode
- 3 control plane nodes (HA)
- N worker nodes
- Calico CNI with IPIP mode
- etcd on control plane nodes
- Suitable for: production, high availability

## Directory Structure

```
phase0-kubernetes-cluster/
├── README.md                  # This file
├── deploy-single-node.sh      # Single-node deployment
├── deploy-multi-node.sh       # Multi-node deployment
├── inventory.ini.template     # Template for multi-node
├── cluster-config.yaml        # Kubespray configuration
└── verify-cluster.sh          # Post-install verification
```

## Manual Setup (Alternative)

If you prefer manual installation:

### 1. Install Dependencies

**Ubuntu 24.04+ (with PEP 668 support):**
```bash
sudo apt-get update
sudo apt-get install -y git python3 python3-pip python3-venv sshpass

# Create virtual environment (required for Ubuntu 24.04+)
python3 -m venv ~/.kubespray-venv
source ~/.kubespray-venv/bin/activate
```

**Ubuntu 22.04 and earlier:**
```bash
sudo apt-get update
sudo apt-get install -y git python3 python3-pip sshpass
```

### 2. Clone Kubespray

```bash
cd /home/ubuntu
git clone https://github.com/kubernetes-sigs/kubespray.git
cd kubespray
git checkout v2.28.1  # Kubespray v2.28.1 for Kubernetes v1.32.8
```

### 3. Install Requirements

```bash
pip3 install -r requirements.txt
```

### 4. Configure Inventory

```bash
# Copy sample inventory
cp -rfp inventory/sample inventory/mycluster

# Update inventory file
declare -a IPS=(10.10.1.3 10.10.1.4 10.10.1.5)
CONFIG_FILE=inventory/mycluster/hosts.yaml python3 contrib/inventory_builder/inventory.py ${IPS[@]}
```

### 5. Configure Kubespray

Edit `inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml`:

```yaml
kube_version: v1.32.8
kube_network_plugin: calico
container_manager: containerd
etcd_deployment_type: host
cluster_name: ai-stack-cluster
```

### 6. Deploy Cluster

```bash
ansible-playbook -i inventory/mycluster/hosts.yaml \
  --become --become-user=root \
  cluster.yml
```

## Post-Installation

### 1. Configure kubectl

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 2. Verify Cluster

```bash
kubectl cluster-info
kubectl get nodes
kubectl get pods --all-namespaces
```

### 3. Install local-path-provisioner (if not installed)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 4. Install metrics-server (if not installed)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

## Verification Checklist

After installation, verify:

- [ ] All nodes are Ready: `kubectl get nodes`
- [ ] All system pods running: `kubectl get pods -n kube-system`
- [ ] DNS working: `kubectl run test --rm -i --image=busybox -- nslookup kubernetes.default`
- [ ] Storage available: `kubectl get storageclass`
- [ ] Metrics working: `kubectl top nodes`

## Troubleshooting

### Nodes Not Ready

```bash
# Check node logs
journalctl -u kubelet -f

# Check system pods
kubectl get pods -n kube-system
kubectl describe pod <pod-name> -n kube-system
```

### DNS Not Working

```bash
# Check CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

### Network Issues

```bash
# Check Calico
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl logs -n kube-system -l k8s-app=calico-node
```

## Cleanup

To remove the cluster:

```bash
cd <project-root>/kubespray
ansible-playbook -i inventory/mycluster/hosts.yaml \
  --become --become-user=root \
  reset.yml
```

## Next Steps

Once Kubernetes is installed and verified:

```bash
cd ../phase1-cluster-istio
./deploy-phase1.sh
```

---

**Note**: If you already have a Kubernetes cluster, you can skip Phase 0 and go directly to Phase 1.
