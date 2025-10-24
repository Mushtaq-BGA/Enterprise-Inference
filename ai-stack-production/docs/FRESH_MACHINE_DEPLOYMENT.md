# Fresh Machine Deployment - Complete Workflow

This document describes exactly what happens when you run the AI Stack deployment on a fresh machine.

## Prerequisites

- Ubuntu 24.04 LTS (or compatible)
- Root/sudo access
- Internet connectivity
- Minimum 4 CPU cores, 8GB RAM (for single-node)

## One-Command Deployment

```bash
git clone <your-repo>
cd ai-stack-production/scripts
./deploy-all.sh --install-k8s
```

## What Happens Behind the Scenes

### Phase 0: Kubernetes Installation (Optional)

**When**: `--install-k8s` flag provided  
**Duration**: 15-30 minutes

```bash
phase0-kubernetes-cluster/deploy-single-node.sh
```

**Actions:**
1. ✓ Installs Kubespray dependencies (Ansible, Python packages)
2. ✓ Generates inventory for single-node cluster
3. ✓ Deploys Kubernetes 1.32 via Kubespray
4. ✓ Configures kubectl access
5. ✓ Verifies cluster health

**Result:**
- Kubernetes 1.32 cluster running
- kubectl configured and working
- CoreDNS with custom domain: `ai-stack-cluster`

---

### Phase 1: Istio Service Mesh

**Duration**: 5-10 minutes

```bash
phase1-cluster-istio/deploy-phase1.sh
```

**Actions:**
1. ✓ Creates namespaces (kserve, litellm, postgres, redis)
2. ✓ Applies RBAC for Istio installation
3. ✓ Installs Istio 1.24.2 (minimal profile)
4. ✓ Enables Istio sidecar injection in kserve namespace
5. ✓ Configures STRICT mTLS globally
6. ✓ Deploys Istio Gateway for ingress
7. ✓ Waits for Istio components to be ready

**Result:**
- Istio control plane running
- Service mesh ready for workloads
- mTLS enforced between services
- Ingress gateway exposed as NodePort

---

### Phase 1.5: Certificate Manager

**Duration**: 2-5 minutes

```bash
phase1.5-cert-manager/deploy-phase1.5.sh
```

**Actions:**
1. ✓ Installs cert-manager v1.16.2
2. ✓ Creates self-signed issuer for internal certs
3. ✓ Creates Let's Encrypt staging issuer
4. ✓ Creates Let's Encrypt production issuer
5. ✓ Waits for cert-manager webhook ready

**Result:**
- Certificate automation ready
- Self-signed certs for internal use
- Let's Encrypt integration available

---

### Phase 2: Knative + KServe

**Duration**: 5-10 minutes

```bash
phase2-knative-kserve/deploy-phase2.sh
```

**Actions:**
1. ✓ Downloads Knative Serving 1.19.4 manifests
2. ✓ Applies Knative CRDs and core components
3. ✓ Configures Istio as networking layer
4. ✓ Downloads KServe v0.15.2 manifests
5. ✓ Applies KServe CRDs and controller
6. ✓ Deploys OpenVINO Model Server runtime
7. ✓ Configures autoscaling (min: 1, max: 3)
8. ✓ Applies sample InferenceService (qwen3-4b-int4-ov)
9. ✓ Waits for model pod to be ready

**Result:**
- Knative Serving ready for serverless workloads
- KServe ready for ML model serving
- Sample model deployed and running (2/2 pods: model + istio-proxy)
- Model serving endpoint: `http://qwen3-4b-int4-ov-predictor.kserve.svc.ai-stack-cluster/v3`

**Key Configuration:**
```yaml
minReplicas: 1  # Model always ready (no cold start)
maxReplicas: 3  # Auto-scales to 3 pods under load
targetConcurrency: 10  # 10 requests per pod
```

---

### Phase 3: LiteLLM Stack

**Duration**: 3-5 minutes

```bash
phase3-litellm-stack/deploy-phase3.sh
```

**Actions:**
1. ✓ Deploys PostgreSQL 16-alpine (stateful, with PVC)
2. ✓ Waits for PostgreSQL to be ready
3. ✓ Initializes database schema (with retry logic)
4. ✓ Deploys Redis 7-alpine for caching
5. ✓ Waits for Redis to be ready
6. ✓ Creates LiteLLM ConfigMap with empty model_list
7. ✓ Deploys LiteLLM proxy (HPA: 3-20 replicas)
8. ✓ Exposes LiteLLM via Istio VirtualService
9. ✓ Waits for LiteLLM to be healthy (600s timeout)
10. ✓ Verifies database connectivity through Istio mTLS

**Result:**
- PostgreSQL ready with `litellm` database
- Redis cache ready
- LiteLLM proxy running (3 replicas initially)
- API accessible at: `http://litellm.litellm.svc.ai-stack-cluster:4000`
- Master API Key: `sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef`

**Network Configuration:**
- PostgreSQL port 5432 excluded from Istio (direct access)
- Redis port 6379 excluded from Istio (direct access)
- LiteLLM uses Istio service mesh for inter-service communication

---

### Phase 4: Model Registration (Production-Standard GitOps) ⭐

**Duration**: 1-2 minutes

```bash
phase4-model-watcher/deploy-phase4.sh
  ↓
discover-and-configure.sh (auto-confirmed)
```

**Actions:**
1. ✓ Cleans up legacy resources (if any exist)
2. ✓ Discovers InferenceServices from KServe namespace
3. ✓ Generates model_list configuration:
   ```yaml
   model_list:
     - model_name: qwen3-4b-int4-ov
       litellm_params:
         model: openai/qwen3-4b-int4-ov
         api_base: http://qwen3-4b-int4-ov-predictor.kserve.svc.ai-stack-cluster/v3
         api_key: dummy
         stream: true
         max_retries: 3
   ```
4. ✓ Merges with base LiteLLM configuration
5. ✓ Updates ConfigMap declaratively via `kubectl apply`
6. ✓ Triggers rolling restart of LiteLLM deployment
7. ✓ Waits for rollout to complete
8. ✓ Verifies models loaded (checks logs)

**Result:**
- Models automatically discovered and registered
- ConfigMap updated (version controlled)
- LiteLLM pods restarted with new configuration
- Models accessible via unified API

**Production Standards:**
- ✅ Declarative (ConfigMap-based, not API calls)
- ✅ Version controlled (Kubernetes API)
- ✅ Automated (no manual intervention)
- ✅ Reproducible (works every time)
- ✅ GitOps compliant

---

### Phase 5: Optimization & Load Testing

**Duration**: 1-2 minutes

```bash
phase5-optimization/deploy-phase5.sh
```

**Actions:**
1. ✓ Applies HPA for LiteLLM (3-20 replicas)
2. ✓ Configures resource limits for all components
3. ✓ Optimizes Knative autoscaling parameters
4. ✓ Provides load testing scripts
5. ✓ Shows monitoring commands

**Result:**
- Production-ready autoscaling configured
- Load testing tools available
- Monitoring commands documented

---

## Complete Stack Overview

After successful deployment, you have:

### Infrastructure
- ✅ Kubernetes 1.28 cluster
- ✅ Istio 1.24.2 service mesh (STRICT mTLS)
- ✅ Cert-manager for certificate automation

### Serverless & ML Serving
- ✅ Knative Serving 1.19.4
- ✅ KServe v0.15.2
- ✅ OpenVINO Model Server runtime
- ✅ Sample model: qwen3-4b-int4-ov (running)

### API Gateway & Storage
- ✅ LiteLLM proxy (unified API)
- ✅ PostgreSQL 16 (metadata & users)
- ✅ Redis 7 (caching)

### Automation
- ✅ Model auto-discovery & registration
- ✅ Horizontal Pod Autoscaling
- ✅ Load-based scaling

## Access the Stack

### Internal Access (from within cluster)

**LiteLLM API:**
```bash
http://litellm.litellm.svc.ai-stack-cluster:4000
```

**Model Endpoint:**
```bash
http://qwen3-4b-int4-ov-predictor.kserve.svc.ai-stack-cluster/v3
```

### External Access (from host machine)

**Via Port-Forward:**
```bash
# LiteLLM API
kubectl port-forward -n litellm svc/litellm 4000:4000

# Test
curl http://localhost:4000/v1/models \
  -H "Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef"
```

**Via Istio Ingress Gateway (NodePort):**
```bash
# Get NodePort
HTTP_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')

# Get Node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Access LiteLLM
curl http://litellm.aistack.local:$HTTP_PORT/v1/models \
  -H "Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef"
```

## Verify Everything Works

### 1. Check All Pods Running
```bash
kubectl get pods --all-namespaces | grep -v Running
# Should be empty (all pods Running)
```

### 2. Verify InferenceService
```bash
kubectl get inferenceservices -n kserve
# NAME                URL                                               READY   PREV   LATEST
# qwen3-4b-int4-ov   http://qwen3-4b-int4-ov.kserve.svc.cluster.local  True           100
```

### 3. List Registered Models
```bash
kubectl port-forward -n litellm svc/litellm 4000:4000 &
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef" | jq .
```

**Expected Output:**
```json
{
  "data": [
    {
      "id": "qwen3-4b-int4-ov",
      "object": "model",
      "owned_by": "openai"
    }
  ],
  "object": "list"
}
```

### 4. Test Inference
```bash
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-4b-int4-ov",
    "messages": [{"role": "user", "content": "Say hello!"}],
    "max_tokens": 50
  }'
```

## Timeline Summary

| Phase | Duration | What Deploys |
|-------|----------|--------------|
| 0 | 15-30 min | Kubernetes cluster |
| 1 | 5-10 min | Istio service mesh |
| 1.5 | 2-5 min | Certificate manager |
| 2 | 5-10 min | Knative + KServe + Sample model |
| 3 | 3-5 min | PostgreSQL + Redis + LiteLLM |
| 4 | 1-2 min | Model discovery & registration |
| 5 | 1-2 min | Optimization & scaling |
| **Total** | **32-64 min** | **Complete AI Stack** |

## Key Features

### ✅ Fully Automated
- One command deploys entire stack
- No manual intervention required
- Models automatically discovered and registered

### ✅ Production-Ready
- GitOps-based configuration
- Service mesh with mTLS
- Horizontal autoscaling
- Health checks and retries

### ✅ Fresh Machine Compatible
- Works on clean Ubuntu installation
- Installs all dependencies
- Self-configuring (cluster domain detection)

### ✅ Scalable
- Knative autoscaling for models
- HPA for LiteLLM (3-20 replicas)
- Redis caching for performance

### ✅ Observable
- Structured logging
- Kubernetes events
- Easy troubleshooting

## Troubleshooting Fresh Deployments

### Issue: Kubernetes Installation Fails
```bash
# Check prerequisites
./phase0-kubernetes-cluster/verify-cluster.sh

# View detailed logs
tail -f deployment-*.log
```

### Issue: Pods Not Starting
```bash
# Check pod status
kubectl get pods --all-namespaces

# Check specific pod logs
kubectl logs <pod-name> -n <namespace>

# Check events
kubectl get events -A --sort-by='.lastTimestamp'
```

### Issue: Models Not Registered
```bash
# Check ConfigMap
kubectl get configmap litellm-config -n litellm -o yaml | grep -A 10 "model_list:"

# Re-run discovery
cd phase4-model-watcher
./discover-and-configure.sh

# Check LiteLLM logs
kubectl logs -n litellm deployment/litellm | grep -i model
```

### Issue: Database Connection Failures
```bash
# Verify PostgreSQL running
kubectl get pods -n postgres

# Check port exclusions (for Istio mTLS bypass)
kubectl get configmap istio-sidecar-injector -n istio-system -o yaml | grep excludeOutboundPorts
# Should include: 5432,6379
```

## Next Steps After Deployment

1. **Deploy More Models**:
   ```bash
   kubectl apply -f your-model-inferenceservice.yaml
   cd phase4-model-watcher
   ./discover-and-configure.sh  # Auto-register new model
   ```

2. **Run Load Tests**:
   ```bash
   cd phase5-optimization
   ./load-test-baseline.sh
   ```

3. **Monitor Performance**:
   ```bash
   kubectl top nodes
   kubectl top pods -A
   kubectl get hpa -A --watch
   ```

4. **Configure External Access**:
   - Set up DNS for your domain
   - Configure TLS certificates via cert-manager
   - Update Istio Gateway with your hostname

## Conclusion

The AI Stack deployment on a fresh machine is:

- ✅ **Fully automated** - one command does everything
- ✅ **Production-standard** - GitOps, service mesh, autoscaling
- ✅ **Self-configuring** - detects cluster domain, configures routes
- ✅ **Reproducible** - works identically on any fresh Ubuntu machine
- ✅ **Complete** - from bare metal to serving ML models

**Total time: ~30-60 minutes from empty machine to production AI stack** 🚀
