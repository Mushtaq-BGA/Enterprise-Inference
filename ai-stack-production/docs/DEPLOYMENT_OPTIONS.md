# Deployment Options - AI Stack Production

This guide explains the two deployment paths: **with** or **without** Kubernetes installation.

---

## Option 1: Deploy on Existing Kubernetes Cluster

**Use this if**: You already have a Kubernetes cluster (v1.28+) installed and accessible.

### Prerequisites
- ✅ Kubernetes v1.28+ already installed
- ✅ `kubectl` configured and authenticated
- ✅ Cluster has sufficient resources (4+ CPU cores, 16GB+ RAM)

### Quick Start

```bash
cd /home/ubuntu/ai-stack-production

# Deploy all phases (1-5) on existing cluster
./scripts/deploy-all.sh
```

The script will:
1. ✅ Check kubectl and cluster access
2. ✅ Deploy Phase 1: Istio + Namespaces
3. ✅ Deploy Phase 2: KServe + Knative
4. ✅ Deploy Phase 3: LiteLLM Stack
5. ✅ Deploy Phase 4: Model Watcher
6. ✅ Deploy Phase 5: Optimization

### Skip Specific Phases

If you already have some components installed:

```bash
# Skip Phase 1 (if Istio already installed)
./scripts/deploy-all.sh --skip-phase 1

# Skip multiple phases
./scripts/deploy-all.sh --skip-phase 1 --skip-phase 2

# Dry run (see what would be deployed)
./scripts/deploy-all.sh --dry-run
```

### Manual Phase Deployment

Deploy phases individually:

```bash
# Phase 1: Istio
cd phase1-cluster-istio
./deploy-phase1.sh

# Phase 2: KServe
cd ../phase2-knative-kserve
./deploy-phase2.sh

# Phase 3: LiteLLM
cd ../phase3-litellm-stack
./deploy-phase3.sh

# Phase 4: Model Watcher
cd ../phase4-model-watcher
./deploy-phase4.sh

# Phase 5: Optimization
cd ../phase5-optimization
./deploy-phase5.sh
```

---

## Option 2: Fresh Installation (Including Kubernetes)

**Use this if**: You need to install Kubernetes from scratch.

### Prerequisites
- ✅ Ubuntu 20.04+ server (Ubuntu 24.04 fully supported)
- ✅ Root/sudo access
- ✅ Minimum 4 CPU cores, 16GB RAM
- ✅ SSH access (for multi-node)

### One-Command Installation (Recommended)

**Single-Node Cluster**:
```bash
cd /home/ubuntu/ai-stack-production

# Install Kubernetes + AI Stack in one command
./scripts/deploy-all.sh --install-k8s
```

**Multi-Node Cluster**:
```bash
cd /home/ubuntu/ai-stack-production

# 1. Create inventory file
cp phase0-kubernetes-cluster/inventory.ini.template phase0-kubernetes-cluster/inventory.ini
vi phase0-kubernetes-cluster/inventory.ini

# 2. Install Kubernetes + AI Stack
./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node
```

This single command will:
1. ✅ Install Kubernetes v1.32.8 via Kubespray
2. ✅ Verify cluster is ready
3. ✅ Deploy all AI Stack components (Phases 1-5)

**Time**: ~45-60 minutes total

### Step-by-Step Installation (Alternative)

### Step-by-Step Installation (Alternative)

If you prefer to run phases separately:

#### Single-Node Installation (Dev/Test)

```bash
cd /home/ubuntu/ai-stack-production/phase0-kubernetes-cluster

# Deploy single-node cluster
./deploy-single-node.sh

# Verify cluster
./verify-cluster.sh
```

This installs:
- Kubernetes v1.32.8
- Kubespray v2.28.1
- containerd runtime
- Calico CNI
- CoreDNS
- local-path-provisioner

**Time**: ~15-20 minutes

#### Multi-Node Installation (Production)

```bash
cd /home/ubuntu/ai-stack-production/phase0-kubernetes-cluster

# 1. Edit inventory with your nodes
vi inventory.ini

# 2. Deploy cluster
./deploy-multi-node.sh

# 3. Verify cluster
./verify-cluster.sh
```

**Time**: ~30-45 minutes

### Step 2: Deploy AI Stack (Phases 1-5)

After Kubernetes is installed:

```bash
cd /home/ubuntu/ai-stack-production

# Deploy all AI stack components
./scripts/deploy-all.sh
```

**Time**: ~15-30 minutes

---

## Comparison: Deployment Methods

| Method | Commands | Time | Use Case |
|--------|----------|------|----------|
| **Existing Cluster** | `./scripts/deploy-all.sh` | 15-30 min | Already have K8s |
| **Fresh (One Command)** | `./scripts/deploy-all.sh --install-k8s` | 45-60 min | Easiest, automated |
| **Fresh (Step-by-Step)** | Phase 0 → `deploy-all.sh` | 45-60 min | More control |
| **Managed K8s** | `./scripts/deploy-all.sh` | 15-30 min | EKS/GKE/AKS |

---

## Quick Decision Tree

```
Do you have Kubernetes installed?
    │
    ├─ YES → Run: ./scripts/deploy-all.sh
    │
    └─ NO  → Choose installation method:
              │
              ├─ One Command (Easiest):
              │    ./scripts/deploy-all.sh --install-k8s
              │
              └─ Step-by-Step (More Control):
                   Step 1: cd phase0-kubernetes-cluster && ./deploy-single-node.sh
                   Step 2: cd .. && ./scripts/deploy-all.sh
```

---

## Architecture Overview

### Phase 0: Kubernetes Cluster (Optional)
**Skip if you already have K8s**

```
Kubespray (Ansible)
    ↓
Kubernetes v1.32.8
    ├── containerd
    ├── Calico CNI
    ├── CoreDNS
    └── local-path-provisioner
```

**Deploy**: `phase0-kubernetes-cluster/deploy-single-node.sh`

---

### Phase 1: Istio + Namespaces (Required)

```
Istio Service Mesh
    ├── istiod (control plane)
    ├── Ingress Gateway (NodePort)
    ├── STRICT mTLS
    └── 6 Namespaces
```

**Deploy**: `phase1-cluster-istio/deploy-phase1.sh`

---

### Phase 2: KServe + Knative (Required)

```
Knative Serving v1.19.4
    ↓
KServe v0.15.2
    ├── ClusterServingRuntime (OpenVINO)
    ├── Scale-to-zero
    └── Auto-scaling
```

**Deploy**: `phase2-knative-kserve/deploy-phase2.sh`

---

### Phase 3: LiteLLM Stack (Required)

```
LiteLLM Router
    ├── PostgreSQL (metadata)
    ├── Redis (cache)
    ├── HPA (3-20 replicas)
    └── Istio VirtualService
```

**Deploy**: `phase3-litellm-stack/deploy-phase3.sh`

---

### Phase 4: Model Watcher (Required)

```
Python Controller
    ├── Watches InferenceService CRDs
    ├── Auto-registers READY models
    └── Auto-deregisters on deletion
```

**Deploy**: `phase4-model-watcher/deploy-phase4.sh`

---

### Phase 5: Optimization (Optional)

```
Performance Tuning
    ├── Load testing scripts
    ├── Optimization guides
    └── Monitoring setup
```

**Deploy**: `phase5-optimization/deploy-phase5.sh`

---

## Quick Decision Tree

```
Do you have Kubernetes installed?
    │
    ├─ YES → Use Option 1 (Existing Cluster)
    │         Run: ./scripts/deploy-all.sh
    │
    └─ NO  → Use Option 2 (Fresh Installation)
              Step 1: cd phase0-kubernetes-cluster && ./deploy-single-node.sh
              Step 2: cd .. && ./scripts/deploy-all.sh
```

---

## Common Scenarios

### Scenario 1: AWS/GCP/Azure with Managed Kubernetes

✅ **Use Option 1** (Existing Cluster)

```bash
# Configure kubectl for your managed cluster
# EKS example:
aws eks update-kubeconfig --region us-west-2 --name my-cluster

# Deploy AI stack
cd /home/ubuntu/ai-stack-production
./scripts/deploy-all.sh
```

---

### Scenario 2: On-Premises Bare Metal (Easiest)

✅ **Use Option 2 - One Command**

```bash
cd /home/ubuntu/ai-stack-production

# Single command installs everything
./scripts/deploy-all.sh --install-k8s
```

---

### Scenario 3: On-Premises Bare Metal (Step-by-Step)

✅ **Use Option 2 - Manual Steps**

```bash
# Install Kubernetes first
cd phase0-kubernetes-cluster
./deploy-single-node.sh  # or deploy-multi-node.sh

# Then deploy AI stack
cd ..
./scripts/deploy-all.sh
```

---

### Scenario 3: Development Laptop (Docker Desktop, Minikube)

✅ **Use Option 1** (Existing Cluster)

```bash
# Start your local cluster
minikube start --cpus=4 --memory=16384

# Deploy AI stack
cd /home/ubuntu/ai-stack-production
./scripts/deploy-all.sh
```

---

### Scenario 4: Existing Cluster with Some Components

✅ **Use Option 1 with Skip Phases**

```bash
# If you already have Istio installed
./scripts/deploy-all.sh --skip-phase 1

# If you have Istio and KServe
./scripts/deploy-all.sh --skip-phase 1 --skip-phase 2
```

---

## Verification

### Check Kubernetes is Ready (Before Deploying Stack)

```bash
# Check cluster info
kubectl cluster-info

# Check nodes
kubectl get nodes

# Check version
kubectl version --short

# Check resources
kubectl top nodes
```

Expected:
- ✅ Cluster accessible
- ✅ All nodes Ready
- ✅ Kubernetes v1.28+
- ✅ Sufficient CPU/memory

---

### Check Stack Deployment (After deploy-all.sh)

```bash
# Check all namespaces
kubectl get ns

# Check all pods
kubectl get pods --all-namespaces

# Check InferenceServices
kubectl get inferenceservice -n kserve

# Check LiteLLM
kubectl get pods -n litellm
```

Expected:
- ✅ 6 namespaces (istio-system, kserve, litellm, etc.)
- ✅ All pods Running
- ✅ InferenceServices Ready
- ✅ LiteLLM pods Running

---

## Troubleshooting

### Issue: kubectl not found

**Solution**: Install kubectl first
```bash
# Ubuntu/Debian
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

---

### Issue: Cannot access Kubernetes cluster

**Solution**: 
- Check kubeconfig: `kubectl config view`
- Test connection: `kubectl cluster-info`
- If no cluster, run Phase 0 first

---

### Issue: Insufficient resources

**Solution**:
- Check nodes: `kubectl top nodes`
- Need minimum: 4 CPU cores, 16GB RAM
- Scale down replicas or add nodes

---

## Time Estimates

| Deployment Type | Phase 0 | Phases 1-5 | Total |
|-----------------|---------|------------|-------|
| **Fresh Single-Node** | 15-20 min | 15-30 min | 30-50 min |
| **Fresh Multi-Node** | 30-45 min | 15-30 min | 45-75 min |
| **Existing Cluster** | 0 min | 15-30 min | 15-30 min |
| **Managed K8s (EKS/GKE/AKS)** | 0 min | 15-30 min | 15-30 min |

---

## Summary

**For Existing Kubernetes Cluster**:
```bash
./scripts/deploy-all.sh
```

**For Fresh Installation**:
```bash
# Step 1: Install Kubernetes
cd phase0-kubernetes-cluster
./deploy-single-node.sh

# Step 2: Deploy AI Stack
cd ..
./scripts/deploy-all.sh
```

**The master script (`deploy-all.sh`) ALWAYS assumes Kubernetes is already installed.**  
**It automatically skips Phase 0 - Kubernetes installation happens separately if needed.**

---

## References

- **Main README**: [README.md](../README.md)
- **Quick Start**: [QUICK_START.md](../QUICK_START.md)
- **Phase 0 Guide**: [phase0-kubernetes-cluster/README.md](../phase0-kubernetes-cluster/README.md)
- **Project Summary**: [PROJECT_SUMMARY.md](../PROJECT_SUMMARY.md)

**Need help?** Check [START_HERE.md](../START_HERE.md) for the complete guide.
