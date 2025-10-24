# Phase 0 Integration - Kubernetes Installation in Main Script

## 🎉 What Changed

The master deployment script (`scripts/deploy-all.sh`) now includes **optional Kubernetes installation**!

You can now install Kubernetes + AI Stack in **one command** instead of two separate steps.

---

## ✅ New Feature: `--install-k8s` Flag

### Before (Two-Step Process)

```bash
# Step 1: Install Kubernetes
cd phase0-kubernetes-cluster
./deploy-single-node.sh

# Step 2: Deploy AI Stack
cd ..
./scripts/deploy-all.sh
```

### After (One Command) ⭐

```bash
# Single command does everything!
./scripts/deploy-all.sh --install-k8s
```

---

## 📋 New Options

### 1. `--install-k8s`
Install Kubernetes before deploying AI Stack

```bash
./scripts/deploy-all.sh --install-k8s
```

**What it does**:
- Installs Kubernetes v1.32.8 via Kubespray v2.28.1
- Runs verification checks
- Proceeds to deploy AI Stack (Phases 1-5)

**Time**: ~45-60 minutes total

---

### 2. `--k8s-mode <MODE>`
Choose Kubernetes installation mode

**Options**:
- `single-node` (default) - For dev/test
- `multi-node` - For production HA

```bash
# Single-node (default)
./scripts/deploy-all.sh --install-k8s

# Multi-node
./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node
```

---

## 🚀 Usage Examples

### Example 1: Fresh Single-Node Installation
```bash
cd /home/ubuntu/ai-stack-production

# One command installs everything
./scripts/deploy-all.sh --install-k8s
```

**Deploys**:
- ✅ Phase 0: Kubernetes v1.32.8 (single-node)
- ✅ Phase 1: Istio + Namespaces
- ✅ Phase 2: KServe + Knative
- ✅ Phase 3: LiteLLM Stack
- ✅ Phase 4: Model Watcher
- ✅ Phase 5: Optimization

---

### Example 2: Fresh Multi-Node Installation
```bash
# 1. Create inventory file
cp phase0-kubernetes-cluster/inventory.ini.template phase0-kubernetes-cluster/inventory.ini
vi phase0-kubernetes-cluster/inventory.ini

# 2. Install Kubernetes + AI Stack
./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node
```

**Deploys**:
- ✅ Phase 0: Kubernetes v1.32.8 (multi-node HA)
- ✅ Phases 1-5: Full AI Stack

---

### Example 3: Install K8s and Skip Some Phases
```bash
# Install Kubernetes but skip Istio (if you want to install it separately)
./scripts/deploy-all.sh --install-k8s --skip-phase 1
```

---

### Example 4: Dry Run
```bash
# See what would be installed without actually installing
./scripts/deploy-all.sh --install-k8s --dry-run
```

---

### Example 5: Deploy on Existing Cluster (No Change)
```bash
# Works exactly as before - no Kubernetes installation
./scripts/deploy-all.sh
```

---

## 🔧 How It Works

### Script Flow with `--install-k8s`

```
./scripts/deploy-all.sh --install-k8s
    ↓
1. Parse arguments
    ↓
2. Display mode: "Fresh Installation (includes Kubernetes)"
    ↓
3. Phase 0: Install Kubernetes
    ├─ Run deploy-single-node.sh (or deploy-multi-node.sh)
    ├─ Verify cluster
    └─ Wait 5 seconds
    ↓
4. Pre-flight checks
    ├─ Check kubectl
    ├─ Check cluster access
    └─ Get cluster info
    ↓
5. Phase 1: Istio + Namespaces
    ↓
6. Phase 2: KServe + Knative
    ↓
7. Phase 3: LiteLLM Stack
    ↓
8. Phase 4: Model Watcher
    ↓
9. Phase 5: Optimization
    ↓
10. Deployment Complete
```

---

### Script Flow WITHOUT `--install-k8s`

```
./scripts/deploy-all.sh
    ↓
1. Parse arguments
    ↓
2. Display mode: "Deploy on Existing Kubernetes Cluster"
    ↓
3. Pre-flight checks (assumes K8s exists)
    ├─ Check kubectl
    ├─ Check cluster access
    └─ Get cluster info
    ↓
4. Phase 1: Istio + Namespaces
    ↓
(... continues with Phases 2-5)
```

---

## 📊 Comparison Matrix

| Scenario | Command | Phases | Time |
|----------|---------|--------|------|
| **Existing K8s Cluster** | `./scripts/deploy-all.sh` | 1-5 | 15-30 min |
| **Fresh Single-Node** | `./scripts/deploy-all.sh --install-k8s` | 0-5 | 45-60 min |
| **Fresh Multi-Node** | `./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node` | 0-5 | 60-90 min |
| **Manual (Old Way)** | Phase 0 → `deploy-all.sh` | 0-5 | 45-60 min |

---

## 🎯 Multi-Node Requirements

For multi-node deployment, you need:

### 1. Create Inventory File

```bash
cp phase0-kubernetes-cluster/inventory.ini.template phase0-kubernetes-cluster/inventory.ini
```

### 2. Edit Inventory

```ini
[all]
node1 ansible_host=192.168.1.10 ip=192.168.1.10
node2 ansible_host=192.168.1.11 ip=192.168.1.11
node3 ansible_host=192.168.1.12 ip=192.168.1.12

[kube_control_plane]
node1
node2
node3

[etcd]
node1
node2
node3

[kube_node]
node1
node2
node3
```

### 3. Deploy

```bash
./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node
```

---

## 🔍 Error Handling

### Multi-Node without Inventory

**Error**:
```
inventory.ini not found for multi-node deployment
Please create inventory.ini from inventory.ini.template
```

**Solution**:
```bash
cp phase0-kubernetes-cluster/inventory.ini.template phase0-kubernetes-cluster/inventory.ini
vi phase0-kubernetes-cluster/inventory.ini
```

---

### Phase 0 Script Not Found

**Error**:
```
Phase 0 directory not found: /path/to/phase0-kubernetes-cluster
```

**Solution**: Ensure you're running from the correct directory:
```bash
cd /home/ubuntu/ai-stack-production
./scripts/deploy-all.sh --install-k8s
```

---

### Kubernetes Installation Fails

**Error**: Phase 0 exits with error

**Solution**:
1. Check logs in deployment log file
2. Verify prerequisites (Ubuntu 20.04+, sudo access)
3. Check network connectivity
4. Run Phase 0 manually for better debugging:
   ```bash
   cd phase0-kubernetes-cluster
   ./deploy-single-node.sh
   ```

---

## 📝 Help Output

```bash
$ ./scripts/deploy-all.sh --help

Usage: ./scripts/deploy-all.sh [OPTIONS]

DEPLOYMENT MODES:

  Mode 1: Deploy on Existing Kubernetes Cluster (default)
    ./scripts/deploy-all.sh

  Mode 2: Fresh Installation (includes Kubernetes)
    ./scripts/deploy-all.sh --install-k8s [--k8s-mode single-node|multi-node]

Options:
  --install-k8s        Install Kubernetes first (Phase 0)
  --k8s-mode MODE      Kubernetes mode: single-node or multi-node (default: single-node)
  --skip-phase N       Skip phase N (can be specified multiple times)
  --dry-run            Show what would be deployed without executing
  --help               Show this help message

Deployment Phases:
  Phase 0: Kubernetes Cluster (optional, use --install-k8s)
  Phase 1: Base Cluster + Istio + Namespaces
  Phase 2: Knative + KServe + Autoscaling
  Phase 3: LiteLLM + Redis + Postgres
  Phase 4: Model Watcher (Auto-registration)
  Phase 5: High Concurrency Optimization

Examples:

  # Deploy on existing cluster (default)
  ./scripts/deploy-all.sh

  # Fresh installation with single-node Kubernetes
  ./scripts/deploy-all.sh --install-k8s

  # Fresh installation with multi-node Kubernetes
  ./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node

  # Skip Phase 1 (if Istio already installed)
  ./scripts/deploy-all.sh --skip-phase 1

  # Install Kubernetes and skip Phase 1
  ./scripts/deploy-all.sh --install-k8s --skip-phase 1

  # Dry run to see what would be deployed
  ./scripts/deploy-all.sh --dry-run

  # Dry run with Kubernetes installation
  ./scripts/deploy-all.sh --install-k8s --dry-run
```

---

## ✅ Benefits

### Before
- 😐 Required two separate commands
- 😐 Had to remember Phase 0 directory
- 😐 Manual verification between steps

### After
- ✅ **One command** installs everything
- ✅ **Automatic verification** after K8s install
- ✅ **Seamless transition** to AI Stack deployment
- ✅ **Dry run support** to preview actions
- ✅ **Flexible modes** (single-node or multi-node)

---

## 🎓 Best Practices

### For Development/Testing
```bash
# Quick single-node setup
./scripts/deploy-all.sh --install-k8s
```

**Time**: ~45-60 minutes  
**Resources**: 1 node, 4 CPU, 16GB RAM

---

### For Production
```bash
# 1. Prepare inventory
cp phase0-kubernetes-cluster/inventory.ini.template phase0-kubernetes-cluster/inventory.ini
vi phase0-kubernetes-cluster/inventory.ini

# 2. Deploy HA cluster + AI Stack
./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node
```

**Time**: ~60-90 minutes  
**Resources**: 3+ nodes, 4 CPU each, 16GB RAM each

---

### For Existing Clusters
```bash
# No change - works as before
./scripts/deploy-all.sh
```

---

## 📚 Documentation Updates

Updated files to reflect this change:

1. **`scripts/deploy-all.sh`**: Added `--install-k8s` and `--k8s-mode` flags
2. **`README.md`**: Updated Quick Start with new one-command option
3. **`DEPLOYMENT_OPTIONS.md`**: Added one-command method as recommended
4. **`PHASE0_INTEGRATION.md`**: This comprehensive guide

---

## 🚀 Quick Reference

### Fresh Installation Commands

```bash
# Single-node (easiest)
./scripts/deploy-all.sh --install-k8s

# Multi-node (production)
./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node

# With phase skipping
./scripts/deploy-all.sh --install-k8s --skip-phase 1

# Dry run
./scripts/deploy-all.sh --install-k8s --dry-run
```

### Existing Cluster Commands

```bash
# Deploy on existing cluster
./scripts/deploy-all.sh

# Skip phases
./scripts/deploy-all.sh --skip-phase 1 --skip-phase 2

# Dry run
./scripts/deploy-all.sh --dry-run
```

---

## 🎉 Summary

**The master deployment script is now truly a "one-command" solution!**

- ✅ Optionally install Kubernetes
- ✅ Choose single-node or multi-node
- ✅ Skip specific phases
- ✅ Dry run support
- ✅ Comprehensive help
- ✅ Backward compatible

**Simplest deployment ever**:
```bash
./scripts/deploy-all.sh --install-k8s
```

**That's it!** ⚡
