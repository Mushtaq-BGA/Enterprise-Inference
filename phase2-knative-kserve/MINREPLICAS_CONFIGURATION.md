# InferenceService minReplicas Configuration

## Issue

When deploying KServe InferenceServices with `minReplicas: 0`, the model pods scale to zero when there's no traffic. This creates several challenges:

1. **"Waiting for load balancer" status**: The InferenceService shows `Ready: Unknown` with the message "Waiting for load balancer to be ready"
2. **Cold start delay**: First request after scale-to-zero can take 30-60+ seconds
3. **Health check failures**: During scale-up, Knative activator may fail to probe pods before they're fully ready
4. **Model registration issues**: Phase 4 model registration fails because endpoints are not responding

## Root Cause

The "Waiting for load balancer" message is misleading. The actual issue is:
- Knative scales the deployment to 0 replicas when idle
- When a request arrives, Knative's activator buffers the request and triggers scale-up
- The model container needs time to start and load the model into memory
- Health checks may timeout during this initialization period
- The InferenceService status doesn't update to "Ready" until successful routing occurs

## Solution

Set `minReplicas: 1` in the InferenceService spec to keep at least one pod running:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: my-model
  namespace: kserve
  annotations:
    autoscaling.knative.dev/min-scale: "1"  # Annotation
spec:
  predictor:
    minReplicas: 1  # Spec field (both are required for consistency)
    maxReplicas: 3
    model:
      # ... model configuration
```

## Trade-offs

### minReplicas: 1 (Recommended)
**Pros:**
- ✅ Model always ready (no cold start)
- ✅ InferenceService shows `Ready: True`
- ✅ Immediate response to requests
- ✅ Works with Phase 4 model registration
- ✅ Better for production workloads

**Cons:**
- ❌ Consumes resources even when idle
- ❌ Higher cost (1 pod always running)

### minReplicas: 0 (Scale-to-Zero)
**Pros:**
- ✅ No resources consumed when idle
- ✅ Lower cost for development/testing
- ✅ Good for infrequently used models

**Cons:**
- ❌ Cold start delay (30-60+ seconds)
- ❌ "Waiting for load balancer" status confusion
- ❌ First request may timeout
- ❌ Model registration requires manual triggering

## Applied Changes

The following files have been updated to use `minReplicas: 1` by default:

1. **`90-sample-inferenceservice.yaml`**:
   - Changed `minReplicas: 0` → `minReplicas: 1`
   - Changed `min-scale: "0"` → `min-scale: "1"`
   - Added comments explaining the trade-off

2. **`deploy-phase2.sh`**:
   - Updated summary to show correct configuration values

## How to Change After Deployment

### Option 1: Patch Existing InferenceService
```bash
kubectl patch inferenceservice <name> -n kserve --type='json' \
  -p='[{"op": "replace", "path": "/spec/predictor/minReplicas", "value": 1}]'
```

### Option 2: Edit InferenceService
```bash
kubectl edit inferenceservice <name> -n kserve
# Change minReplicas from 0 to 1, save and exit
```

### Option 3: Redeploy
```bash
# Update YAML file
kubectl apply -f your-inferenceservice.yaml
```

## Verification

After setting minReplicas: 1, verify the pod is running:

```bash
# Check InferenceService status
kubectl get inferenceservice -n kserve

# Check pods
kubectl get pods -n kserve

# Test model endpoint
POD_IP=$(kubectl get pod -n kserve -l serving.knative.dev/service=<model-name> \
  -o jsonpath='{.items[0].status.podIP}')
kubectl run test --image=curlimages/curl:latest --rm -i --restart=Never \
  --command -- curl http://$POD_IP:8080/v3/models
```

## For Fresh Machine Deployment

With the updated configuration in this repository, fresh deployments will:

1. Deploy InferenceService with `minReplicas: 1` by default
2. Model pods will start immediately after deployment
3. InferenceService will become Ready once pods are healthy
4. Phase 4 model registration will work without manual intervention

## Customization

To use scale-to-zero on a fresh machine, override the default:

```bash
# Before deploying
export SKIP_SAMPLE_INFERENCESERVICE=true
./deploy-phase2.sh

# Then deploy your own InferenceService with minReplicas: 0
```

Or edit `90-sample-inferenceservice.yaml` before deploying Phase 2.
