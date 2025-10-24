# AI Stack Production - Quick Start Guide

## 🎯 What You Have

A **production-ready, modular AI model serving platform** with:

- ✅ **Istio Service Mesh** - Unified L7 gateway with mTLS
- ✅ **KServe + Knative** - Serverless autoscaling (scale-to-zero)
- ✅ **LiteLLM** - OpenAI-compatible API router
- ✅ **Auto-Discovery** - Models registered automatically
- ✅ **High Concurrency** - 1000+ concurrent requests
- ✅ **Robust & Modular** - Clean separation of concerns

## 📁 Project Structure

```
ai-stack-production/
├── README.md                           # Complete documentation
├── QUICK_START.md                      # This file
│
├── phase1-cluster-istio/               # Base infrastructure
│   ├── 00-namespaces.yaml             # Core namespaces
│   ├── 01-istio-minimal.yaml          # Istio (istiod + ingress)
│   ├── 02-mtls-strict.yaml            # STRICT mTLS policies
│   ├── 03-gateway.yaml                # Unified gateway
│   └── deploy-phase1.sh               # Deployment script
│
├── phase2-knative-kserve/              # Model serving platform
│   ├── download-manifests.sh          # Downloads Knative/KServe
│   ├── 03-knative-config.yaml         # Autoscaling config
│   ├── 12-kserve-config.yaml          # KServe predictors
│   ├── 90-sample-inferenceservice.yaml # Test model
│   └── deploy-phase2.sh               # Deployment script
│
├── phase3-litellm-stack/               # API gateway + storage
│   ├── 00-postgres.yaml               # PostgreSQL StatefulSet
│   ├── 01-redis.yaml                  # Redis cache
│   ├── 02-litellm-config.yaml         # LiteLLM configuration
│   ├── 03-litellm-deployment.yaml     # LiteLLM + HPA + PDB
│   ├── 04-litellm-virtualservice.yaml # Istio routing
│   └── deploy-phase3.sh               # Deployment script
│
├── phase4-model-watcher/               # Auto-registration
│   ├── 00-rbac-config.yaml            # RBAC + config
│   ├── 01-deployment.yaml             # Watcher deployment
│   └── deploy-phase4.sh               # Deployment script
│
├── phase5-optimization/                # Performance tuning
│   ├── README.md                      # Optimization guide
│   ├── load-test-baseline.sh          # Performance test
│   ├── load-test-rampup.sh            # Concurrency test
│   └── deploy-phase5.sh               # Setup script
│
├── controllers/
│   └── model_watcher.py               # Python auto-discovery (550 lines)
│
└── scripts/
    └── deploy-all.sh                  # Master deployment script
```

## ⚡ Quick Deployment (5 Commands)

```bash
# 1. Navigate to project
cd /home/ubuntu/ai-stack-production

# 2. Deploy everything
./scripts/deploy-all.sh

# 3. Add DNS entry
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "$NODE_IP litellm.aistack.local" | sudo tee -a /etc/hosts

# 4. Deploy a test model
kubectl apply -f phase2-knative-kserve/90-sample-inferenceservice.yaml

# 5. Test it
curl http://litellm.aistack.local:30080/health
```

## 🧪 Verification Steps

### 1. Check All Pods Running

```bash
kubectl get pods --all-namespaces
```

Expected namespaces:
- `istio-system` - Istio control plane
- `knative-serving` - Knative components
- `kserve` - KServe models
- `litellm` - LiteLLM API router
- `redis` - Redis cache
- `postgres` - PostgreSQL database
- `model-watcher` - Auto-registration controller

### 2. Verify Model Auto-Registration

```bash
# Watch watcher logs
kubectl logs -f -n model-watcher deployment/model-watcher

# Check registered models
curl http://litellm.aistack.local:30080/v1/models \
  -H "Authorization: Bearer sk-1234567890abcdef1234567890abcdef"
```

### 3. Test Chat Completion

```bash
curl -X POST http://litellm.aistack.local:30080/v1/chat/completions \
  -H "Authorization: Bearer sk-1234567890abcdef1234567890abcdef" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen25-3b-int4-test",
    "messages": [{"role": "user", "content": "Hello, how are you?"}],
    "max_tokens": 50
  }'
```

## 🎛️ Key Components

### Istio (Phase 1)
- **Ingress Gateway**: NodePort 30080 (HTTP), 30443 (HTTPS)
- **mTLS**: STRICT mode enabled mesh-wide
- **Gateway**: Wildcard DNS `*.aistack.local`

### KServe (Phase 2)
- **Autoscaling**: 0-10 replicas per model
- **Scale-to-zero**: After 5 minutes idle
- **Concurrency Target**: 100 requests/pod

### LiteLLM (Phase 3)
- **Replicas**: 3-20 (HPA based on CPU 70%, Memory 80%)
- **Workers**: 4 per pod
- **Max Parallel**: 1000 requests per pod
- **Cache**: Redis (600s TTL)
- **Database**: PostgreSQL (10Gi)

### Model Watcher (Phase 4)
- **Watches**: InferenceService CRDs
- **Auto-registers**: READY models → LiteLLM
- **Auto-deregisters**: DELETED models
- **Syncs**: Existing models on startup

## 📊 Default Configuration

| Component | Min | Max | Target |
|-----------|-----|-----|--------|
| LiteLLM Replicas | 3 | 20 | CPU 70% |
| KServe Model Replicas | 0 | 10 | 100 concurrent |
| Redis Memory | - | 2GB | LRU eviction |
| PostgreSQL Storage | - | 10Gi | - |
| Request Timeout | - | 600s | - |
| Retry Attempts | - | 3 | - |

## 🔧 Common Operations

### Scale LiteLLM

```bash
# Manual
kubectl scale deployment litellm -n litellm --replicas=10

# Adjust HPA
kubectl patch hpa litellm-hpa -n litellm --type=merge \
  -p '{"spec":{"maxReplicas":50}}'
```

### Deploy New Model

```bash
# Create InferenceService YAML
cat <<EOF | kubectl apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: my-model
  namespace: kserve
  annotations:
    autoscaling.knative.dev/min-scale: "0"
    autoscaling.knative.dev/max-scale: "5"
spec:
  predictor:
    containers:
    - name: kserve-container
      image: openvino/model_server:2025.3.0
      args:
      - --model_name=my-model
      - --model_path=/mnt/models
      - --rest_port=8080
EOF

# Watch auto-registration
kubectl logs -f -n model-watcher deployment/model-watcher
```

### View Logs

```bash
# LiteLLM
kubectl logs -n litellm deployment/litellm -f

# Model Watcher
kubectl logs -n model-watcher deployment/model-watcher -f

# Istio Gateway
kubectl logs -n istio-system deployment/istio-ingressgateway -f

# Specific model
kubectl logs -n kserve <model-pod-name> -c kserve-container
```

### Check Resource Usage

```bash
# Nodes
kubectl top nodes

# Pods
kubectl top pods -A

# Specific namespace
kubectl top pods -n litellm
```

## 🐛 Troubleshooting

### Problem: Pods not getting Istio sidecar

```bash
# Fix namespace label
kubectl label namespace litellm istio-injection=enabled --overwrite
kubectl rollout restart deployment litellm -n litellm
```

### Problem: Model not auto-registering

```bash
# Check watcher logs
kubectl logs -n model-watcher deployment/model-watcher

# Check InferenceService status
kubectl get inferenceservice -n kserve
kubectl describe inferenceservice <name> -n kserve

# Check if model is READY
kubectl get inferenceservice <name> -n kserve -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

### Problem: High latency

```bash
# Check if models scaled up
kubectl get pods -n kserve

# Check LiteLLM queue
kubectl logs -n litellm deployment/litellm | grep queue

# Check HPA status
kubectl get hpa -n litellm
```

### Problem: Connection refused

```bash
# Check services
kubectl get svc -A

# Test internal connectivity
kubectl run test --rm -i --restart=Never --image=curlimages/curl:latest -n litellm -- \
  curl -v http://litellm.litellm.svc.cluster.local:4000/health
```

## 🚀 Load Testing

```bash
cd phase5-optimization

# Baseline test (100 concurrent, 60s)
./load-test-baseline.sh

# Ramp-up test (100 → 1000 concurrent)
./load-test-rampup.sh
```

## 📈 Monitoring

### Kubernetes Dashboard

```bash
kubectl proxy
# Access: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
```

### Istio Dashboard (if installed)

```bash
kubectl port-forward -n istio-system svc/kiali 20001:20001
# Access: http://localhost:20001
```

### Prometheus Metrics

```bash
# Port-forward Prometheus
kubectl port-forward -n istio-system svc/prometheus 9090:9090

# Key metrics:
# - http_requests_total{namespace="litellm"}
# - kserve_model_concurrency
# - redis_cache_hits_total
```

## 🔒 Security Notes

⚠️ **IMPORTANT**: Before production use:

1. **Change API Keys**:
   ```bash
   kubectl edit configmap litellm-config -n litellm
   kubectl edit secret model-watcher-secret -n model-watcher
   ```

2. **Replace TLS Certificate**:
   ```bash
   # Use Let's Encrypt or your CA
   kubectl create secret tls aistack-tls-cert -n istio-system \
     --cert=fullchain.pem --key=privkey.pem
   ```

3. **Update PostgreSQL Password**:
   ```bash
   kubectl edit secret postgres-secret -n postgres
   ```

4. **Enable Redis Authentication**:
   ```bash
   kubectl edit configmap redis-config -n redis
   # Add: requirepass your-secure-password
   ```

## 📚 Next Steps

1. **Read Full Documentation**: `cat README.md`
2. **Review Optimization Guide**: `cat phase5-optimization/README.md`
3. **Deploy Your Models**: Create InferenceService YAMLs
4. **Set Up Monitoring**: Install Prometheus + Grafana
5. **Configure Backups**: PostgreSQL data backup
6. **Enable Observability**: Distributed tracing with Jaeger

## 🎓 Learn More

- **Phases**: Each phase has its own `deploy-phaseN.sh` with detailed logging
- **Manifests**: All YAML files are heavily commented
- **Controller**: `controllers/model_watcher.py` is well-documented
- **Load Testing**: Phase 5 includes baseline and ramp-up tests

## ✅ Success Criteria

Your deployment is successful when:

- ✅ All pods in `Running` state
- ✅ LiteLLM health check returns 200 OK
- ✅ Models auto-register in LiteLLM
- ✅ Chat completion requests succeed
- ✅ Autoscaling triggers under load
- ✅ No error logs in watcher

## 🆘 Getting Help

1. Check logs: `kubectl logs -n <namespace> <pod-name>`
2. Describe resources: `kubectl describe <resource> <name> -n <namespace>`
3. Review README.md troubleshooting section
4. Check deployment logs: `ai-stack-production/deployment-*.log`

---

**Happy AI Model Serving! 🚀**
