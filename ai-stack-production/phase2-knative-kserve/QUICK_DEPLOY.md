# Quick Deploy Guide - OpenVINO Models with KServe

## 🚀 Deploy in 3 Steps

### Step 1: Choose Your Model

Browse available OpenVINO INT4 models on HuggingFace:
- [OpenVINO Organization](https://huggingface.co/OpenVINO)

Popular models:
- **Qwen3-8B-int4-ov** (8B parameters, INT4 quantized)
- **Phi-3.5-mini-instruct-int4-ov** (3.8B parameters)
- **Llama-3.2-3B-Instruct-int4-ov** (3B parameters)

### Step 2: Create InferenceService YAML

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: my-model
  namespace: kserve
  annotations:
    autoscaling.knative.dev/min-scale: "0"
    autoscaling.knative.dev/max-scale: "5"
    sidecar.istio.io/inject: "true"
spec:
  predictor:
    model:
      runtime: kserve-openvino
      modelFormat:
        name: huggingface
      args:
        - --source_model=OpenVINO/MODEL-NAME
        - --model_repository_path=/tmp
        - --task=text_generation
        - --target_device=CPU
      resources:
        requests:
          cpu: "2"
          memory: "4Gi"
        limits:
          cpu: "4"
          memory: "8Gi"
```

### Step 3: Deploy

```bash
# Apply the YAML
kubectl apply -f my-model.yaml

# Wait for ready (first download may take 5-10 minutes)
kubectl wait --for=condition=Ready inferenceservice/my-model -n kserve --timeout=600s

# Check status
kubectl get inferenceservice my-model -n kserve

# Get URL
kubectl get inferenceservice my-model -n kserve -o jsonpath='{.status.url}'
```

## 📋 Common Model Sizes

| Model | Parameters | INT4 Size | Min Memory | Recommended CPU |
|-------|------------|-----------|------------|-----------------|
| Phi-3.5-mini | 3.8B | ~2.5 GB | 4Gi | 2 cores |
| Llama-3.2-3B | 3B | ~2 GB | 3Gi | 2 cores |
| Qwen3-8B | 8B | ~5 GB | 8Gi | 4 cores |
| Mistral-7B | 7B | ~4.5 GB | 6Gi | 4 cores |

## 🎯 Deployment Patterns

### Pattern 1: Development/Testing (Scale-to-Zero)
```yaml
annotations:
  autoscaling.knative.dev/min-scale: "0"    # Scale to zero when idle
  autoscaling.knative.dev/max-scale: "3"    # Limited scaling
  autoscaling.knative.dev/scale-down-delay: "5m"
```

**Use case**: Dev/test environments, infrequent usage  
**Cost**: Minimal (only runs when needed)  
**Latency**: Cold start ~30-60s first time

### Pattern 2: Production (Always Warm)
```yaml
annotations:
  autoscaling.knative.dev/min-scale: "1"    # Always keep 1 pod
  autoscaling.knative.dev/max-scale: "10"   # Scale up under load
  autoscaling.knative.dev/target: "50"      # 50 concurrent req/pod
```

**Use case**: Production with moderate traffic  
**Cost**: 1 pod always running  
**Latency**: No cold start, sub-100ms response

### Pattern 3: High Traffic (Multi-Replica)
```yaml
annotations:
  autoscaling.knative.dev/min-scale: "3"    # Keep 3 pods minimum
  autoscaling.knative.dev/max-scale: "20"   # Scale to 20 pods
  autoscaling.knative.dev/target: "30"      # Lower concurrency per pod
```

**Use case**: High-traffic production  
**Cost**: 3+ pods always running  
**Latency**: Consistently low, high throughput

## 🔧 Performance Tuning

### CPU Optimization (High Throughput)
```yaml
args:
  - --source_model=OpenVINO/MODEL-NAME
  - --model_repository_path=/tmp
  - --task=text_generation
  - --target_device=CPU
  - --plugin_config={"PERFORMANCE_HINT":"THROUGHPUT","NUM_STREAMS":"4"}
  - --nireq=8
resources:
  requests:
    cpu: "4"
    memory: "8Gi"
```

### Latency Optimization (Low Latency)
```yaml
args:
  - --source_model=OpenVINO/MODEL-NAME
  - --model_repository_path=/tmp
  - --task=text_generation
  - --target_device=CPU
  - --plugin_config={"PERFORMANCE_HINT":"LATENCY"}
  - --nireq=2
resources:
  requests:
    cpu: "2"
    memory: "4Gi"
```

## 📊 Monitoring

### Check Status
```bash
# List all models
kubectl get inferenceservice -n kserve

# Check specific model
kubectl describe inferenceservice my-model -n kserve

# Watch pods (see autoscaling in action)
kubectl get pods -n kserve -w
```

### View Logs
```bash
# Get pod name
POD=$(kubectl get pods -n kserve -l serving.kserve.io/inferenceservice=my-model -o jsonpath='{.items[0].metadata.name}')

# View logs
kubectl logs -n kserve $POD -c kserve-container

# Follow logs
kubectl logs -n kserve $POD -c kserve-container -f
```

### Test Inference
```bash
# Get service URL
ISVC_URL=$(kubectl get inferenceservice my-model -n kserve -o jsonpath='{.status.url}')

# Test with curl (through Istio ingress)
curl -H "Host: my-model.kserve.aistack.local" \
  http://NODE_IP:30080/v2/models/my-model/infer \
  -X POST \
  -d '{"inputs": [{"name": "input", "shape": [1], "datatype": "BYTES", "data": ["Hello world"]}]}'
```

## 🛠️ Troubleshooting

### Model Not Ready
```bash
# Check events
kubectl describe inferenceservice my-model -n kserve | tail -20

# Check pod status
kubectl get pods -n kserve -l serving.kserve.io/inferenceservice=my-model

# Check init container (downloads model)
kubectl logs -n kserve $POD -c storage-initializer
```

**Common issues**:
- ❌ HuggingFace download timeout → Increase `--timeout=600s` in wait command
- ❌ Out of memory → Increase memory limits
- ❌ Storage full → Check `/tmp` space or use PVC

### Pod Crashes
```bash
# Check logs
kubectl logs -n kserve $POD -c kserve-container --previous

# Check events
kubectl get events -n kserve --sort-by='.lastTimestamp'
```

**Common issues**:
- ❌ OOM killed → Model too large for memory limits
- ❌ Model not found → Check `--source_model` path
- ❌ CPU insufficient → Increase CPU requests

### Slow Inference
```bash
# Check pod resources
kubectl top pods -n kserve

# Check HPA status
kubectl get hpa -n kserve

# Check concurrency
kubectl describe inferenceservice my-model -n kserve | grep -A 5 "Conditions"
```

**Solutions**:
- ⚡ Increase CPU cores
- ⚡ Use THROUGHPUT mode with multiple streams
- ⚡ Increase `nireq` (inference request queue)
- ⚡ Lower `target` concurrency per pod

## 📚 Complete Examples

See [EXAMPLES.yaml](EXAMPLES.yaml) for 8 complete examples:
1. ✅ Qwen3-8B from HuggingFace (recommended starter)
2. ✅ Phi-3.5-mini (lightweight model)
3. ✅ LLaMA 3.2-3B (Meta's model)
4. ✅ PVC storage (pre-downloaded models)
5. ✅ S3 storage (cloud storage)
6. ✅ ONNX models
7. ✅ High-traffic configuration
8. ✅ Low-latency configuration

## 🎓 Best Practices

### ✅ DO
- Use INT4 quantized models for better CPU performance
- Start with `min-scale: 0` for development
- Set appropriate memory limits (model size + 2GB overhead)
- Use `--plugin_config` for performance tuning
- Monitor with `kubectl top pods`

### ❌ DON'T
- Don't use FP32 models on CPU (too slow)
- Don't set memory limits too low (will OOM)
- Don't use high `nireq` with low CPU (wasted memory)
- Don't forget to set `max-scale` (can exhaust cluster)

## 🔗 References

- **Phase 2 README**: [README.md](README.md) - Complete deployment guide
- **Runtime Docs**: [OPENVINO_RUNTIME.md](OPENVINO_RUNTIME.md) - Detailed runtime configuration
- **HuggingFace Models**: https://huggingface.co/OpenVINO
- **OpenVINO Docs**: https://docs.openvino.ai/latest/ovms_what_is_openvino_model_server.html

## 🚀 Quick Commands Cheat Sheet

```bash
# Deploy
kubectl apply -f my-model.yaml

# Check status
kubectl get inferenceservice -n kserve

# Wait for ready
kubectl wait --for=condition=Ready inferenceservice/my-model -n kserve --timeout=600s

# Get URL
kubectl get inferenceservice my-model -n kserve -o jsonpath='{.status.url}'

# View logs
kubectl logs -n kserve -l serving.kserve.io/inferenceservice=my-model -c kserve-container

# Delete
kubectl delete inferenceservice my-model -n kserve

# Scale manually (override autoscaling)
kubectl patch inferenceservice my-model -n kserve --type merge -p '{"spec":{"predictor":{"minReplicas":3}}}'

# Watch autoscaling
kubectl get pods -n kserve -w -l serving.kserve.io/inferenceservice=my-model
```

---

**Ready to deploy?** Start with the sample model:
```bash
kubectl apply -f 90-sample-inferenceservice.yaml
```
