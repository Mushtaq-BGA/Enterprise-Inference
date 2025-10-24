# AI Stack - Production-Grade Deployment

> **Modular, Robust, High-Concurrency AI Model Serving Platform**

A complete production-ready AI stack built on Kubernetes with Istio service mesh, KServe for model serving, and LiteLLM as an OpenAI-compatible API router. Designed for high concurrency (1000+ concurrent requests) with automatic model discovery and registration.

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     External Traffic                             │
│              (*.aistack.local → NodePort 30080/30443)           │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────────┐
│                   Istio Ingress Gateway                         │
│                    (L7 Load Balancer)                           │
│          • mTLS enabled  • Circuit Breaking                     │
│          • Rate Limiting • Retry Logic                          │
└──────┬──────────────────────────────────────────────┬──────────┘
       │                                               │
       │ VirtualService                                │ VirtualService
       │ (litellm.*)                                   │ (*.kserve.*)
       ▼                                               ▼
┌──────────────────┐                          ┌──────────────────┐
│    LiteLLM       │─────mTLS─────────────────▶│  KServe Models  │
│  (API Router)    │                          │  (Serverless)   │
│                  │                          │                  │
│ • 3-20 replicas  │                          │ • Auto-scaling  │
│ • HPA enabled    │                          │ • Scale-to-zero │
│ • Redis cache    │                          │ • OpenVINO MS   │
│ • PostgreSQL DB  │                          │ • 0-10 replicas │
└─────┬────────────┘                          └──────────────────┘
      │                                                ▲
      │ mTLS                                          │
      ▼                                               │
┌─────────────┐  ┌─────────────┐      ┌─────────────────────────┐
│   Redis     │  │  PostgreSQL │      │   Model Watcher         │
│  (Cache)    │  │  (Metadata) │      │  (Auto-registration)    │
│             │  │             │      │                         │
│ • 2GB LRU   │  │ • 10Gi PVC  │      │ • Watches KServe CRDs   │
│ • 10k conns │  │ • Connection│      │ • Registers in LiteLLM  │
│             │  │   pooling   │      │ • Syncs on startup      │
└─────────────┘  └─────────────┘      └─────────────────────────┘
```

## ✨ Features

### Core Capabilities
- **🚀 High Concurrency**: Handle 1000+ concurrent requests
- **🔄 Auto-Scaling**: KServe serverless with scale-to-zero
- **🤖 Auto-Discovery**: Automatic model registration via watcher
- **🔒 Security**: STRICT mTLS, AuthorizationPolicies, RBAC
- **⚡ Performance**: Redis caching, connection pooling, circuit breaking
- **📊 Observability**: Prometheus metrics, distributed tracing ready
- **🔌 OpenAI Compatible**: Drop-in replacement for OpenAI API

### Model Serving
- **KServe v0.15.2**: Industry-standard model serving
- **Knative**: Serverless autoscaling with scale-to-zero
- **OpenVINO Model Server**: Optimized CPU inference (INT4/INT8 support)
- **Custom Runtimes**: Easily add PyTorch, TensorFlow, ONNX

### API Gateway
- **LiteLLM**: Unified OpenAI-compatible API
- **Multi-Model Routing**: Load balancing across replicas
- **Request Queuing**: Handle traffic spikes gracefully
- **Caching**: Reduce latency and model server load

## 📋 Prerequisites

### Option A: Existing Kubernetes Cluster
- **Kubernetes**: v1.28+ (single-node or multi-node)
- **kubectl**: Configured and authenticated

### Option B: Fresh Installation (Phase 0)
- **Ubuntu**: 20.04+ server(s) (24.04 fully supported with automatic venv)
- **Kubespray**: v2.28.1 (installs Kubernetes v1.32.8)
- **Root/sudo access**: Required for installation
- **Python**: 3.8+ (virtual environment automatically created on Ubuntu 24.04+)

### Common Requirements
- **Resources**: 
  - Minimum: 4 CPU cores, 16GB RAM
  - Recommended: 8+ CPU cores, 32GB+ RAM
- **Storage**: 50GB+ available

## 🚀 Quick Start

> **📖 See [DEPLOYMENT_OPTIONS.md](DEPLOYMENT_OPTIONS.md) for detailed deployment paths**

### Two Deployment Options

#### Option A: Existing Kubernetes Cluster

**If you already have Kubernetes v1.28+ installed**:

```bash
cd /home/ubuntu/ai-stack-production

# Deploy AI Stack (Phases 1-5)
./scripts/deploy-all.sh
```

#### Option B: Fresh Installation (Including Kubernetes)

**If you need to install Kubernetes first**:

```bash
cd /home/ubuntu/ai-stack-production

# One command installs Kubernetes + AI Stack
./scripts/deploy-all.sh --install-k8s

# Or for multi-node cluster:
./scripts/deploy-all.sh --install-k8s --k8s-mode multi-node
```

### Advanced Options

```bash
# Skip specific phases
./scripts/deploy-all.sh --skip-phase 1

# Install Kubernetes and skip a phase
./scripts/deploy-all.sh --install-k8s --skip-phase 1

# Dry run
./scripts/deploy-all.sh --dry-run

# Show all options
./scripts/deploy-all.sh --help
```

### Manual Phase Deployment

Deploy phases individually for more control:

```bash
# Phase 0: Kubernetes Cluster (if needed)
cd phase0-kubernetes-cluster
chmod +x deploy-single-node.sh
./deploy-single-node.sh

# Phase 1: Base Cluster + Istio
cd ../phase1-cluster-istio
chmod +x deploy-phase1.sh
./deploy-phase1.sh

# Phase 2: Knative + KServe
cd ../phase2-knative-kserve
chmod +x deploy-phase2.sh
./deploy-phase2.sh

# Phase 3: LiteLLM Stack
cd ../phase3-litellm-stack
chmod +x deploy-phase3.sh
./deploy-phase3.sh

# Phase 4: Model Watcher
cd ../phase4-model-watcher
chmod +x deploy-phase4.sh
./deploy-phase4.sh

# Phase 5: Optimization (documentation + tools)
cd ../phase5-optimization
chmod +x deploy-phase5.sh
./deploy-phase5.sh
```

## 📦 Deployment Phases

### Phase 0: Kubernetes Cluster Setup (Optional)
**Duration**: ~10-20 minutes

If you don't have Kubernetes installed:
- ✅ Deploys Kubernetes v1.32.8 using Kubespray v2.28.1
- ✅ Single-node or multi-node configurations
- ✅ Containerd runtime
- ✅ Calico CNI
- ✅ CoreDNS
- ✅ local-path-provisioner for storage
- ✅ metrics-server

**Files**:
- `deploy-single-node.sh` - Automated single-node setup
- `deploy-multi-node.sh` - Automated multi-node setup
- `inventory.ini.template` - Multi-node inventory template
- `verify-cluster.sh` - Post-install validation

### Phase 1: Base Cluster + Istio + Namespaces
**Duration**: ~5 minutes

Creates foundational infrastructure:
- ✅ Istio minimal installation (istiod + ingress gateway)
- ✅ Namespaces with sidecar injection labels
- ✅ STRICT mTLS policies
- ✅ Unified Istio Gateway (wildcard DNS)
- ✅ TLS certificate (self-signed for dev)

**Files**:
- `00-namespaces.yaml` - Core namespaces
- `01-istio-minimal.yaml` - Istio control plane
- `02-mtls-strict.yaml` - mTLS + AuthorizationPolicies
- `03-gateway.yaml` - Unified gateway

### Phase 2: Knative + KServe + Autoscaling
**Duration**: ~10 minutes

Deploys model serving platform:
- ✅ Knative Serving (CRDs + Core + Istio networking)
- ✅ Autoscaling configuration (scale-to-zero, targets)
- ✅ KServe CRDs and controller
- ✅ InferenceService configuration
- ✅ Sample model deployment (optional)

**Files**:
- `00-knative-serving-crds.yaml` - Knative CRDs (downloaded)
- `01-knative-serving-core.yaml` - Knative core (downloaded)
- `02-knative-istio-networking.yaml` - Networking layer (downloaded)
- `03-knative-config.yaml` - Autoscaling settings
- `10-kserve-crds.yaml` - KServe CRDs (downloaded)
- `11-kserve-controller.yaml` - KServe controller (downloaded)
- `12-kserve-config.yaml` - KServe predictors config
- `90-sample-inferenceservice.yaml` - Test model

### Phase 3: LiteLLM + Redis + Postgres
**Duration**: ~8 minutes

Deploys API gateway and dependencies:
- ✅ PostgreSQL StatefulSet (10Gi storage)
- ✅ Redis deployment (2GB cache, LRU eviction)
- ✅ LiteLLM deployment (3-20 replicas with HPA)
- ✅ Istio VirtualService (routing, CORS, retries)
- ✅ Connection pooling and circuit breaking

**Files**:
- `00-postgres.yaml` - PostgreSQL StatefulSet
- `01-redis.yaml` - Redis deployment + config
- `02-litellm-config.yaml` - LiteLLM configuration
- `03-litellm-deployment.yaml` - LiteLLM + HPA + PDB
- `04-litellm-virtualservice.yaml` - Istio routing

### Phase 4: Model Watcher (Auto-Registration)
**Duration**: ~3 minutes

Deploys automatic model discovery:
- ✅ Python watcher watching InferenceService CRDs
- ✅ Auto-registers READY models in LiteLLM
- ✅ Auto-deregisters DELETED models
- ✅ Syncs existing models on startup
- ✅ RBAC with ClusterRole

**Files**:
- `00-rbac-config.yaml` - ServiceAccount, ClusterRole, ConfigMap, Secret
- `01-deployment.yaml` - Watcher deployment
- `../controllers/model_watcher.py` - Python controller (550 lines)

### Phase 5: High Concurrency Optimization
**Duration**: ~1 minute (documentation only)

Provides tuning tools:
- ✅ Optimization guidelines
- ✅ Load testing scripts (baseline, ramp-up)
- ✅ Monitoring queries
- ✅ Troubleshooting guide

**Files**:
- `README.md` - Complete optimization guide
- `load-test-baseline.sh` - Baseline performance test
- `load-test-rampup.sh` - Gradual concurrency increase
- `deploy-phase5.sh` - Setup script

## 🧪 Testing

### Quick Setup: HTTPS + Local Access

Run the automated setup script to configure HTTPS and test connectivity:

```bash
./scripts/setup-local-https.sh
```

This script will automatically:
- ✅ Check/create TLS certificates
- ✅ Verify gateway HTTPS configuration  
- ✅ Update /etc/hosts with correct hostname
- ✅ Test HTTPS connectivity
- ✅ Display access URLs and API key

**See [HTTPS Setup Guide](scripts/HTTPS_SETUP_README.md) for complete documentation.**

### Manual Setup

#### 1. Add to /etc/hosts

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "$NODE_IP litellm.aistack.local" | sudo tee -a /etc/hosts
```

#### 2. Health Check

```bash
# HTTP
curl http://litellm.aistack.local:30080/health

# HTTPS (with self-signed cert)
curl -k https://litellm.aistack.local:32443/health/readiness
```

#### 3. Deploy a Model

```bash
kubectl apply -f phase2-knative-kserve/90-sample-inferenceservice.yaml

# Watch for auto-registration
kubectl logs -f -n model-watcher deployment/model-watcher
```

#### 4. List Models

```bash
# HTTP
curl http://litellm.aistack.local:30080/v1/models \
  -H "Authorization: Bearer sk-1234567890abcdef1234567890abcdef"

# HTTPS
curl -k https://litellm.aistack.local:32443/v1/models \
  -H "Authorization: Bearer sk-1234567890abcdef1234567890abcdef"
```

#### 5. Chat Completion

```bash
# HTTP
curl -X POST http://litellm.aistack.local:30080/v1/chat/completions \
  -H "Authorization: Bearer sk-1234567890abcdef1234567890abcdef" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen25-3b-int4-test",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'

# HTTPS
curl -k -X POST https://litellm.aistack.local:32443/v1/chat/completions \
  -H "Authorization: Bearer sk-1234567890abcdef1234567890abcdef" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen25-3b-int4-test",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'
```

#### 6. Load Testing

```bash
cd phase5-optimization

# Baseline test (100 concurrent users, 60s)
./load-test-baseline.sh

# Ramp-up test (100 → 1000 concurrent)
./load-test-rampup.sh
```

## 📊 Performance Targets

| Metric | Target | Typical (4-core node) |
|--------|--------|-----------------------|
| Max Concurrent Requests | 1000 | 800-1200 |
| Latency P50 | <100ms | 50-80ms |
| Latency P95 | <500ms | 200-400ms |
| Latency P99 | <1000ms | 500-800ms |
| Throughput | >500 req/s | 400-700 req/s |
| Error Rate | <1% | 0.1-0.5% |

## 🔧 Configuration

### Scaling LiteLLM

```bash
# Manual scaling
kubectl scale deployment litellm -n litellm --replicas=10

# Adjust HPA
kubectl patch hpa litellm-hpa -n litellm --type=merge \
  -p '{"spec":{"maxReplicas":50}}'
```

### Scaling KServe Models

```bash
# Update InferenceService
kubectl patch inferenceservice qwen25-3b-int4-test -n kserve --type=merge \
  -p '{"spec":{"predictor":{"minReplicas":2,"maxReplicas":20}}}'
```

### Adjusting Timeouts

```bash
# Increase VirtualService timeout
kubectl patch virtualservice litellm-vs -n litellm --type=merge \
  -p '{"spec":{"http":[{"timeout":"900s"}]}}'
```

## 🔍 Monitoring

### Check Pod Status

```bash
# All pods
kubectl get pods --all-namespaces

# Specific namespaces
kubectl get pods -n istio-system
kubectl get pods -n litellm
kubectl get pods -n kserve

# Resource usage
kubectl top nodes
kubectl top pods -A
```

### View Logs

```bash
# LiteLLM
kubectl logs -f -n litellm deployment/litellm

# Model Watcher
kubectl logs -f -n model-watcher deployment/model-watcher

# Istio Ingress Gateway
kubectl logs -f -n istio-system deployment/istio-ingressgateway
```

### Check HPA Status

```bash
kubectl get hpa -n litellm
kubectl describe hpa litellm-hpa -n litellm
```

### InferenceService Status

```bash
kubectl get inferenceservice -n kserve
kubectl describe inferenceservice qwen25-3b-int4-test -n kserve
```

## 🐛 Troubleshooting

### Pods Not Getting Istio Sidecar

```bash
# Check namespace label
kubectl get namespace litellm --show-labels

# Fix label
kubectl label namespace litellm istio-injection=enabled --overwrite

# Restart deployment
kubectl rollout restart deployment litellm -n litellm
```

### LiteLLM Health Check Failed

```bash
# Check logs
kubectl logs -n litellm deployment/litellm --tail=100

# Check database connection
kubectl run pg-test --rm -i --restart=Never --image=postgres:16-alpine -n postgres \
  --env="PGPASSWORD=litellm_secure_password_change_in_production" \
  --command -- psql -h postgres.postgres.svc.cluster.local -U litellm -d litellm -c "SELECT 1;"

# Check Redis connection
kubectl run redis-test --rm -i --restart=Never --image=redis:7-alpine -n redis \
  --command -- redis-cli -h redis.redis.svc.cluster.local ping
```

### Model Not Auto-Registering

```bash
# Check watcher logs
kubectl logs -n model-watcher deployment/model-watcher

# Check InferenceService status
kubectl get inferenceservice -n kserve
kubectl describe inferenceservice <name> -n kserve

# Manually test registration
kubectl run test --rm -i --restart=Never --image=curlimages/curl:latest -n model-watcher -- \
  curl -X POST http://litellm.litellm.svc.cluster.local:4000/model/new \
  -H "Authorization: Bearer sk-1234567890abcdef1234567890abcdef" \
  -H "Content-Type: application/json" \
  -d '{"model_name":"test","litellm_params":{"model":"openai/test","api_base":"http://test:80/v3"}}'
```

### High Latency

1. Check if models are scaled up:
   ```bash
   kubectl get pods -n kserve
   ```

2. Check LiteLLM queue:
   ```bash
   kubectl logs -n litellm deployment/litellm | grep queue
   ```

3. Check circuit breaker status:
   ```bash
   istioctl proxy-config clusters deployment/litellm.litellm | grep outlier
   ```

## 🔐 Security

### Production Checklist

- [ ] Change default API key in all components
- [ ] Replace self-signed TLS cert with production cert (Let's Encrypt)
- [ ] Update PostgreSQL password
- [ ] Enable Redis authentication
- [ ] Configure network policies
- [ ] Set up RBAC with least privilege
- [ ] Enable audit logging
- [ ] Configure backup for PostgreSQL
- [ ] Set up monitoring and alerting
- [ ] Review and update resource limits

### Change API Key

```bash
# Update LiteLLM config
kubectl edit configmap litellm-config -n litellm
# Change: master_key: "your-secure-key"

# Update watcher secret
kubectl edit secret model-watcher-secret -n model-watcher
# Change: LITELLM_API_KEY

# Restart services
kubectl rollout restart deployment litellm -n litellm
kubectl rollout restart deployment model-watcher -n model-watcher
```

## 🗑️ Cleanup

### Remove Specific Phase

```bash
# Phase 4
kubectl delete -f phase4-model-watcher/01-deployment.yaml
kubectl delete -f phase4-model-watcher/00-rbac-config.yaml

# Phase 3
kubectl delete -f phase3-litellm-stack/04-litellm-virtualservice.yaml
kubectl delete -f phase3-litellm-stack/03-litellm-deployment.yaml
kubectl delete -f phase3-litellm-stack/01-redis.yaml
kubectl delete -f phase3-litellm-stack/00-postgres.yaml
```

### Complete Cleanup

```bash
# Delete all namespaces (cascading delete)
kubectl delete namespace model-watcher kserve litellm redis postgres istio-system knative-serving

# Or use a cleanup script
./scripts/cleanup-all.sh  # (create if needed)
```

## 📚 Additional Resources

- **Istio Documentation**: https://istio.io/latest/docs/
- **KServe Documentation**: https://kserve.github.io/website/
- **Knative Documentation**: https://knative.dev/docs/
- **LiteLLM Documentation**: https://docs.litellm.ai/
- **OpenVINO Model Server**: https://docs.openvino.ai/latest/ovms_what_is_openvino_model_server.html

## 🤝 Contributing

Contributions welcome! Please follow these guidelines:
1. Test changes in a development environment
2. Update documentation for new features
3. Follow existing code style and structure
4. Add deployment validation steps

## 📄 License

This project is licensed under the MIT License.

## 🙏 Acknowledgments

Built with:
- **Kubernetes** - Container orchestration
- **Istio** - Service mesh
- **KServe** - Model serving platform
- **Knative** - Serverless autoscaling
- **LiteLLM** - OpenAI-compatible API router
- - **OpenVINO** - Optimized CPU inference with ClusterServingRuntime

---

**Version**: 1.1.1  
**Last Updated**: October 18, 2025  
**Status**: Production Ready  
**Ubuntu 24.04**: Fully supported with automatic Python venv (see [UBUNTU_24.04_NOTES.md](UBUNTU_24.04_NOTES.md))  
**Latest**: CPU-optimized OpenVINO runtime with dynamic autoscaling (see [CHANGELOG.md](CHANGELOG.md))

```
