# Phase 2: Knative Serving + KServe

This phase installs the serverless model serving platform:
- **Knative Serving**: Serverless autoscaling with scale-to-zero
- **KServe**: Model serving framework built on Knative
- **OpenVINO Runtime**: ClusterServingRuntime for CPU-optimized inference

## What Gets Installed

### Knative Serving v1.19.4
- **CRDs**: Service, Configuration, Revision, Route
- **Core Components**:
  - `controller`: Manages Knative resources
  - `webhook`: Validates and mutates resources
  - `activator`: Handles scale-from-zero
  - `autoscaler`: HPA-based autoscaling
- **Istio Networking**: Integration with Istio service mesh

### KServe v0.15.2
- **CRDs**: InferenceService, TrainedModel, ClusterServingRuntime
- **Controller**: Manages InferenceService lifecycle
- **OpenVINO Runtime**: Pre-configured ClusterServingRuntime for OpenVINO models

### Autoscaling Configuration
- **Min Scale**: 0 (scale-to-zero enabled)
- **Max Scale**: 10 replicas per model
- **Target Concurrency**: 100 requests per pod
- **Scale Down Delay**: 5 minutes of inactivity
- **Metrics**: Concurrency-based autoscaling

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  InferenceService (CRD)                     │
│  • Defines model: name, format, storage, resources          │
│  • Autoscaling: min/max replicas, target concurrency        │
└────────────────────┬────────────────────────────────────────┘
                     │
                     │ KServe Controller creates
                     ▼
┌─────────────────────────────────────────────────────────────┐
│              Knative Service (Revision)                     │
│  • Serverless deployment with scale-to-zero                 │
│  • Automatic traffic routing                                │
│  • Gradual rollout support                                  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     │ Creates Pod with runtime
                     ▼
┌─────────────────────────────────────────────────────────────┐
│        ClusterServingRuntime: kserve-openvino               │
│  • Container: openvino/model_server:2025.3                │
│  • Formats: OpenVINO, ONNX, TensorFlow, HuggingFace        │
│  • Protocol: REST (v1, v2) + gRPC                           │
│  • Auto-selection based on model format                     │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### Deploy Phase 2

```bash
cd /home/ubuntu/ai-stack-production/phase2-knative-kserve
./deploy-phase2.sh
```

The script will:
1. ✅ Download Knative v1.19.4 and KServe v0.15.2 manifests
2. ✅ Install Knative Serving CRDs
3. ✅ Deploy Knative core components
4. ✅ Configure autoscaling settings
5. ✅ Install Knative-Istio networking
6. ✅ Install KServe CRDs
7. ✅ Deploy KServe controller
8. ✅ Install OpenVINO ClusterServingRuntime
9. ✅ Configure KServe with storage and ingress
10. ✅ Automatically deploy sample InferenceService (set `SKIP_SAMPLE_INFERENCESERVICE=true` to skip)

> **Tip:** To skip the sample model during automation or CI, run `SKIP_SAMPLE_INFERENCESERVICE=true ./deploy-phase2.sh`.

### Verify Installation

```bash
# Check Knative components
kubectl get pods -n knative-serving

# Check KServe controller
kubectl get pods -n kserve

# Check ClusterServingRuntime
kubectl get clusterservingruntimes.serving.kserve.io

# List InferenceServices
kubectl get inferenceservices -n kserve
```

## Files

| File | Purpose |
|------|---------|
| `download-manifests.sh` | Downloads Knative v1.19.4 and KServe v0.15.2 manifests |
| `03-knative-config.yaml` | Autoscaling configuration (scale-to-zero, concurrency) |
| `11-openvino-runtime.yaml` | OpenVINO ClusterServingRuntime definition |
| `12-kserve-config.yaml` | KServe storage and ingress configuration |
| `90-sample-inferenceservice.yaml` | Example InferenceService for testing |
| `deploy-phase2.sh` | Automated deployment script |

## ClusterServingRuntime vs Old Approach

### ❌ Old Way (Deprecated)
```yaml
# ConfigMap with predictor definition
data:
  predictors: |-
    {
      "openvino_model_server": {
    "image": "openvino/model_server",
    "defaultImageVersion": "2025.3"
      }
    }

# InferenceService with containers
spec:
  predictor:
    containers:
    - name: kserve-container
  image: openvino/model_server:2025.3
      args: [...]
```

**Problems**:
- Hard-coded container configuration
- No runtime reusability
- Difficult to maintain
- No format auto-selection

### ✅ New Way (ClusterServingRuntime)
```yaml
# Reusable ClusterServingRuntime
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterServingRuntime
metadata:
  name: kserve-openvino
spec:
  supportedModelFormats:
  - name: openvino
    autoSelect: true
  containers:
  - image: openvino/model_server:2025.3
    args: [...]

# Simple InferenceService
spec:
  predictor:
    model:
      modelFormat:
        name: openvino
      storageUri: "pvc://models/my-model"
```

**Benefits**:
- ✅ Reusable runtime across all InferenceServices
- ✅ Auto-selection based on model format
- ✅ Centralized configuration
- ✅ Easy to update runtime image
- ✅ Support multiple formats (OpenVINO, ONNX, TF)

## Creating InferenceServices

### Example: Deploy OpenVINO Model

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: my-model
  namespace: kserve
  annotations:
    autoscaling.knative.dev/min-scale: "0"
    autoscaling.knative.dev/max-scale: "5"
    autoscaling.knative.dev/target: "100"
    serving.kserve.io/deploymentMode: "Serverless"
spec:
  predictor:
    minReplicas: 0
    maxReplicas: 5
    model:
      modelFormat:
        name: openvino  # Auto-selects kserve-openvino runtime
      storageUri: "pvc://model-storage/my-model"
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          cpu: "2"
          memory: 4Gi
```

### Apply the InferenceService

```bash
kubectl apply -f my-model.yaml
kubectl get inferenceservice my-model -n kserve
kubectl wait --for=condition=Ready inferenceservice/my-model -n kserve
```

### Check Status

```bash
# Get InferenceService URL
kubectl get inferenceservice my-model -n kserve -o jsonpath='{.status.url}'

# Check pods (should scale to 0 after inactivity)
kubectl get pods -n kserve -l serving.kserve.io/inferenceservice=my-model

# Test the model
ISVC_URL=$(kubectl get inferenceservice my-model -n kserve -o jsonpath='{.status.url}')
curl -H "Host: my-model.kserve.aistack.local" http://NODE_IP:30080/v1/models/my-model
```

## Storage Options

### 1. PVC (Recommended for Production)
```yaml
storageUri: "pvc://model-storage-pvc/path/to/model"
```

Create PVC:
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-storage-pvc
  namespace: kserve
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: local-path
EOF
```

### 2. S3 Compatible Storage
```yaml
storageUri: "s3://bucket-name/path/to/model"
```

Configure credentials:
```bash
kubectl create secret generic s3-credentials \
  -n kserve \
  --from-literal=AWS_ACCESS_KEY_ID=xxx \
  --from-literal=AWS_SECRET_ACCESS_KEY=yyy \
  --from-literal=AWS_ENDPOINT_URL=https://s3.example.com
```

### 3. HTTP/HTTPS
```yaml
storageUri: "https://example.com/models/my-model.tar.gz"
```

### 4. HuggingFace Hub
```yaml
storageUri: "hf://organization/model-name"
```

## Autoscaling Configuration

KServe supports advanced autoscaling with multiple metrics and fine-grained control.

### Basic Annotations

| Annotation | Default | Description |
|------------|---------|-------------|
| `autoscaling.knative.dev/min-scale` | 0 | Minimum replicas (0 = scale-to-zero) |
| `autoscaling.knative.dev/max-scale` | 10 | Maximum replicas |
| `autoscaling.knative.dev/target` | 100 | Target concurrent requests per pod |
| `autoscaling.knative.dev/metric` | concurrency | Metric to use (concurrency, rps, cpu) |
| `autoscaling.knative.dev/scale-down-delay` | 5m | Wait before scaling down |

### Advanced Annotations (Production-Ready)

| Annotation | Recommended | Description |
|------------|-------------|-------------|
| `autoscaling.knative.dev/target-utilization-percentage` | 70 | Target CPU utilization % |
| `autoscaling.knative.dev/class` | kpa.autoscaling.knative.dev | Autoscaler class (KPA or HPA) |
| `autoscaling.knative.dev/window` | 60s | Observation window for metrics |
| `autoscaling.knative.dev/panic-window-percentage` | 10 | Quick response window (% of window) |
| `autoscaling.knative.dev/panic-threshold-percentage` | 200 | Aggressive scale-up threshold (2x target) |

### Example: Production Workload (Dual-Metric)

**Use case**: CPU-intensive LLM inference with variable load

```yaml
annotations:
  # Basic scaling limits
  autoscaling.knative.dev/min-scale: "1"          # Keep 1 pod warm (no cold starts)
  autoscaling.knative.dev/max-scale: "10"         # Scale up to 10 pods
  
  # Dual-metric autoscaling: concurrency + CPU
  autoscaling.knative.dev/target: "10"            # Scale at 10 concurrent requests/pod
  autoscaling.knative.dev/metric: "cpu"           # Monitor CPU utilization
  autoscaling.knative.dev/target-utilization-percentage: "70"  # Scale at 70% CPU
  autoscaling.knative.dev/class: "kpa.autoscaling.knative.dev"
  
  # Scaling behavior tuning
  autoscaling.knative.dev/scale-down-delay: "30s"  # Quick scale-down (avoid thrashing)
  autoscaling.knative.dev/window: "60s"            # 60s observation for stability
  autoscaling.knative.dev/panic-window-percentage: "10"   # 6s quick response
  autoscaling.knative.dev/panic-threshold-percentage: "200"  # 2x target = panic scale
spec:
  predictor:
    minReplicas: 1    # Must match min-scale annotation
    maxReplicas: 10   # Must match max-scale annotation
    scaleTarget: 10   # Must match target annotation
    scaleMetric: concurrency
```

**Benefits**:
- ✅ Scales on both concurrency AND CPU (whichever hits first)
- ✅ Aggressive scale-up for traffic spikes (6s panic window)
- ✅ Conservative scale-down to avoid thrashing (30s delay)
- ✅ Stable decisions with 60s observation window
- ✅ Tested with 333x throughput improvement (1→2 replicas)

### Example: High-Traffic Model

**Use case**: Many small requests, high throughput

```yaml
annotations:
  autoscaling.knative.dev/min-scale: "2"      # Always keep 2 pods
  autoscaling.knative.dev/max-scale: "20"     # Scale up to 20 pods
  autoscaling.knative.dev/target: "50"        # 50 concurrent requests/pod
  autoscaling.knative.dev/metric: "concurrency"
```

### Example: Low-Latency Model

**Use case**: Critical path, must respond fast

```yaml
annotations:
  autoscaling.knative.dev/min-scale: "1"      # Always keep 1 pod warm
  autoscaling.knative.dev/max-scale: "5"      # Don't scale too high
  autoscaling.knative.dev/target: "10"        # Low concurrency target
  autoscaling.knative.dev/scale-down-delay: "10m"  # Slower scale-down
```

### Example: Cost-Optimized (Scale-to-Zero)

**Use case**: Development/staging, infrequent access

```yaml
annotations:
  autoscaling.knative.dev/min-scale: "0"      # Scale to zero when idle
  autoscaling.knative.dev/max-scale: "3"      # Limited scale
  autoscaling.knative.dev/scale-down-delay: "1m"  # Quick scale-down
```

### Monitoring Autoscaling

Check autoscaler status:
```bash
# View KPA (Knative Pod Autoscaler) resources
kubectl get kpa -n kserve

# Watch replica count in real-time
watch kubectl get pods -n kserve -l serving.kserve.io/inferenceservice=<model-name>

# Check CPU/memory usage
kubectl top pods -n kserve -l serving.kserve.io/inferenceservice=<model-name>
```

### Performance Impact

Based on load testing with Qwen3-4B-INT4-OV model:

| Replicas | Concurrent Requests | TTFT | Throughput | Notes |
|----------|---------------------|------|------------|-------|
| 1 | 10 (large payload) | 4000ms | 75 tok/s | Overloaded |
| 2 | 20 (large payload) | 11ms | 25,000 tok/s | **333x faster!** |
| 2 | 100 (medium payload) | 15ms | 16,260 tok/s | Optimal |
| 2 | 250 (medium payload) | 43ms | 6,413 req/s | High throughput |

**Key insight**: Autoscaling from 1→2 replicas provides massive performance gains for CPU-intensive workloads.

## Monitoring

### Check Autoscaling Metrics

```bash
# Watch pods scaling
kubectl get pods -n kserve -w

# Check Knative revisions
kubectl get revisions -n kserve

# View autoscaler metrics
kubectl get hpa -n kserve
```

### Prometheus Metrics

OpenVINO Model Server exposes metrics at `/metrics:8080`:
- Request count
- Request latency
- Model inference time
- Queue size

Configure ServiceMonitor:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kserve-openvino
  namespace: kserve
spec:
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: my-model
  endpoints:
  - port: metrics
    path: /metrics
```

## Troubleshooting

### InferenceService not ready

**Check status**:
```bash
kubectl describe inferenceservice my-model -n kserve
kubectl get pods -n kserve
```

**Common issues**:
1. ClusterServingRuntime not found
2. Storage initializer failed to download model
3. Insufficient resources
4. Model format mismatch

### Pods not scaling

**Check autoscaler logs**:
```bash
kubectl logs -n knative-serving -l app=autoscaler
```

**Verify metrics**:
```bash
kubectl get hpa -n kserve
kubectl describe hpa <hpa-name> -n kserve
```

### Model fails to load

**Check init container**:
```bash
kubectl logs -n kserve <pod-name> -c storage-initializer
```

**Check model container**:
```bash
kubectl logs -n kserve <pod-name> -c kserve-container
```

### Scale-to-zero not working

**Check Knative config**:
```bash
kubectl get configmap config-autoscaler -n knative-serving -o yaml
```

Ensure:
- `enable-scale-to-zero: "true"`
- `scale-to-zero-grace-period: "30s"`

## Performance Tuning

See [OPENVINO_RUNTIME.md](OPENVINO_RUNTIME.md) for detailed OpenVINO performance tuning.

### CPU Optimization
```yaml
spec:
  predictor:
    model:
      args:
      - --plugin_config={"PERFORMANCE_HINT":"THROUGHPUT"}
      - --nireq=8
      resources:
        requests:
          cpu: "4"
```

### Latency Optimization
```yaml
spec:
  predictor:
    model:
      args:
      - --plugin_config={"PERFORMANCE_HINT":"LATENCY"}
      - --nireq=2
      resources:
        requests:
          cpu: "2"
```

## Next Steps

After Phase 2 is complete:

1. **Verify**: Check all components are running
2. **Test**: Deploy sample InferenceService
3. **Phase 3**: Deploy LiteLLM for OpenAI-compatible API
   ```bash
   cd ../phase3-litellm-stack
   ./deploy-phase3.sh
   ```

## References

- [Knative Documentation](https://knative.dev/docs/)
- [KServe Documentation](https://kserve.github.io/website/)
- [ClusterServingRuntime Guide](https://kserve.github.io/website/latest/modelserving/servingruntimes/)
- [OpenVINO Model Server](https://docs.openvino.ai/latest/ovms_what_is_openvino_model_server.html)
- [OpenVINO Runtime Configuration](OPENVINO_RUNTIME.md)
