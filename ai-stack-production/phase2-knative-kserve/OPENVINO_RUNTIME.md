# OpenVINO Runtime for KServe

This document explains the OpenVINO ClusterServingRuntime configuration used in this deployment.

## Overview

Instead of using the old `predictors` ConfigMap approach, we now use **ClusterServingRuntime** which is the modern KServe way to define model serving runtimes.

**Reference**: [dtrawins/kserve OpenVINO Runtime](https://github.com/dtrawins/kserve/blob/openvino/config/runtimes/kserve-openvino.yaml)

## Architecture

```
┌─────────────────────────────────────────────┐
│         InferenceService CRD                │
│  (defines model: format, storage, runtime)  │
└────────────────┬────────────────────────────┘
                 │
                 │ references
                 ▼
┌─────────────────────────────────────────────┐
│     ClusterServingRuntime: kserve-openvino  │
│  • Container image: openvino/model_server   │
│  • Supported formats: OpenVINO, ONNX, TF    │
│  • Protocol: v1, v2, grpc-v2                │
│  • Auto-select based on model format        │
└────────────────┬────────────────────────────┘
                 │
                 │ creates pod with
                 ▼
┌─────────────────────────────────────────────┐
│       OpenVINO Model Server Container       │
│  • Image: openvino/model_server:2025.3    │
│  • REST API: port 8080                      │
│  • gRPC: port 9000                          │
│  • Model path: /mnt/models                  │
│  • Security: non-root user (5000)           │
└─────────────────────────────────────────────┘
```

## ClusterServingRuntime Configuration

### Key Features

1. **Multi-Format Support**:
   - OpenVINO IR (priority 1)
   - ONNX (priority 2)
   - TensorFlow (priority 3)
   - HuggingFace models (priority 4)

2. **Auto-Selection**: KServe automatically selects this runtime based on the `modelFormat.name` in InferenceService

3. **Protocol Support**:
   - RESTful API (v1, v2)
   - gRPC (grpc-v2)

4. **Security**:
   - Runs as non-root user (UID 5000)
   - No privilege escalation
   - All capabilities dropped

5. **Monitoring**:
   - Prometheus metrics at `/metrics:8080`

### Container Configuration

```yaml
containers:
- args:
  - --model_name={{.Name}}        # Dynamic from InferenceService
  - --model_path=/mnt/models      # Where model files are mounted
  - --port=9000                   # gRPC port
  - --rest_port=8080              # REST API port
  - --file_system_poll_wait_seconds=0  # No polling
  image: openvino/model_server:2025.3
  resources:
    requests:
      cpu: "1"
      memory: 2Gi
    limits:
      cpu: "2"
      memory: 4Gi
```

## InferenceService Usage

### Old Way (Container-based)
```yaml
# ❌ Old approach - not recommended
spec:
  predictor:
    containers:
    - name: kserve-container
  image: openvino/model_server:2025.3
      args: [...]
```

### New Way (ClusterServingRuntime)
```yaml
# ✅ Recommended approach
spec:
  predictor:
    model:
      modelFormat:
        name: openvino          # Auto-selects kserve-openvino runtime
      runtime: kserve-openvino  # Optional: explicit runtime
      storageUri: "pvc://model-storage-pvc/model-name"
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
```

## Model Format Priority

When you create an InferenceService with `modelFormat.name`, KServe automatically selects the runtime with the highest priority for that format:

| Format      | Priority | Runtime Selected |
|-------------|----------|------------------|
| openvino    | 1        | kserve-openvino  |
| onnx        | 2        | kserve-openvino  |
| tensorflow  | 3        | kserve-openvino  |
| huggingface | 4        | kserve-openvino  |

## Storage Configuration

### Option 1: PVC (Production)
```yaml
storageUri: "pvc://model-storage-pvc/path/to/model"
```

### Option 2: S3 Compatible Storage
```yaml
storageUri: "s3://bucket-name/path/to/model"
```

### Option 3: HTTP/HTTPS
```yaml
storageUri: "https://huggingface.co/model-name"
```

### Option 4: Git Repository
```yaml
storageUri: "git://github.com/user/repo"
```

## Example InferenceService

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: my-openvino-model
  namespace: kserve
  annotations:
    autoscaling.knative.dev/min-scale: "0"
    autoscaling.knative.dev/max-scale: "5"
    serving.kserve.io/deploymentMode: "Serverless"
spec:
  predictor:
    minReplicas: 0
    maxReplicas: 5
    model:
      modelFormat:
        name: openvino
      runtime: kserve-openvino
      storageUri: "pvc://models/my-model"
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          cpu: "2"
          memory: 4Gi
```

## Verification

### 1. Check ClusterServingRuntime exists
```bash
kubectl get clusterservingruntimes.serving.kserve.io
```

Expected output:
```
NAME              DISABLED   MODELTYPE   CONTAINERS   AGE
kserve-openvino   false                  ["kserve-container"]    1m
```

### 2. Describe the runtime
```bash
kubectl describe clusterservingruntimes.serving.kserve.io kserve-openvino
```

### 3. Check supported formats
```bash
kubectl get clusterservingruntimes.serving.kserve.io kserve-openvino -o jsonpath='{.spec.supportedModelFormats[*].name}'
```

Expected output:
```
openvino onnx tensorflow huggingface
```

### 4. Deploy test InferenceService
```bash
kubectl apply -f 90-sample-inferenceservice.yaml
kubectl get inferenceservice -n kserve
```

### 5. Check InferenceService uses the runtime
```bash
kubectl get inferenceservice qwen25-3b-int4-test -n kserve -o yaml | grep -A 5 "runtime:"
```

## Troubleshooting

### Runtime not found
**Error**: `ClusterServingRuntime "kserve-openvino" not found`

**Solution**:
```bash
kubectl apply -f 11-openvino-runtime.yaml
kubectl get clusterservingruntimes.serving.kserve.io
```

### Model format mismatch
**Error**: `No matching ClusterServingRuntime for model format`

**Solution**: Ensure `modelFormat.name` matches one of:
- `openvino`
- `onnx`
- `tensorflow`
- `huggingface`

### Pod fails to start
**Check logs**:
```bash
kubectl get pods -n kserve
kubectl logs -n kserve <pod-name> kserve-container
```

Common issues:
- Model files not found in storageUri
- Insufficient memory/CPU resources
- PVC not mounted correctly

### Storage initializer fails
**Check init container logs**:
```bash
kubectl logs -n kserve <pod-name> -c storage-initializer
```

## Customization

### Adjust Resources
Edit `11-openvino-runtime.yaml`:
```yaml
resources:
  requests:
    cpu: "2"      # Increase for better performance
    memory: 4Gi   # Increase for larger models
  limits:
    cpu: "4"
    memory: 8Gi
```

### Add Custom Arguments
Edit the `args` section in `11-openvino-runtime.yaml`:
```yaml
args:
- --model_name={{.Name}}
- --model_path=/mnt/models
- --port=9000
- --rest_port=8080
- --file_system_poll_wait_seconds=0
- --target_device=CPU                          # CPU, GPU, AUTO
- --plugin_config={"PERFORMANCE_HINT":"LATENCY"}  # or THROUGHPUT
- --nireq=4                                    # Number of infer requests
- --log_level=INFO                             # DEBUG, INFO, WARNING, ERROR
```

### Use GPU
If you have GPU nodes:
```yaml
resources:
  requests:
    nvidia.com/gpu: 1
  limits:
    nvidia.com/gpu: 1
args:
- --target_device=GPU
```

## Performance Tuning

### CPU Optimization
```yaml
args:
- --plugin_config={"PERFORMANCE_HINT":"THROUGHPUT","NUM_STREAMS":"4"}
- --nireq=8
resources:
  requests:
    cpu: "4"
    memory: 8Gi
```

### Latency Optimization
```yaml
args:
- --plugin_config={"PERFORMANCE_HINT":"LATENCY"}
- --nireq=2
resources:
  requests:
    cpu: "2"
    memory: 4Gi
```

## References

- [KServe ClusterServingRuntime Documentation](https://kserve.github.io/website/latest/modelserving/servingruntimes/)
- [OpenVINO Model Server GitHub](https://github.com/openvinotoolkit/model_server)
- [KServe OpenVINO Runtime Example](https://github.com/dtrawins/kserve/blob/openvino/config/runtimes/kserve-openvino.yaml)
- [OpenVINO Model Server Documentation](https://docs.openvino.ai/latest/ovms_what_is_openvino_model_server.html)

## Next Steps

1. Deploy your models using InferenceService with `modelFormat.name: openvino`
2. Configure autoscaling parameters in annotations
3. Set up model storage (PVC, S3, etc.)
4. Monitor metrics via Prometheus
5. Integrate with LiteLLM (Phase 3) for OpenAI-compatible API
