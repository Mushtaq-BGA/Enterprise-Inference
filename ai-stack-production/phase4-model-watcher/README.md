# Phase 4: Model Registration (Production-Standard GitOps)

## Overview

Phase 4 implements **production-standard model registration** for LiteLLM using a **ConfigMap-based declarative approach** following Kubernetes GitOps best practices.

## Production Standards Applied

✅ **Declarative Configuration**: Models defined in ConfigMap, not database  
✅ **Version Controlled**: Changes tracked through Kubernetes API  
✅ **Immutable Infrastructure**: Configuration changes trigger pod restarts  
✅ **GitOps Compliant**: All changes via `kubectl apply`  
✅ **Separation of Concerns**: KServe manages models, LiteLLM routes traffic  
✅ **Audit Trail**: ConfigMap revisions provide clear history  

## Architecture

```
┌─────────────────┐
│ InferenceService│  (KServe manages model serving)
│   (qwen3-4b)    │
└────────┬────────┘
         │
         │ Discovery
         ▼
┌─────────────────────┐
│ discover-and-       │  (Scans KServe, generates config)
│ configure.sh        │
└────────┬────────────┘
         │
         │ Updates
         ▼
┌─────────────────────┐
│ litellm-config      │  (ConfigMap with model_list)
│ ConfigMap           │
└────────┬────────────┘
         │
         │ Mounts
         ▼
┌─────────────────────┐
│ LiteLLM Pods        │  (Loads config, serves requests)
└─────────────────────┘
```

## How It Works

### 1. Discovery Phase
```bash
./discover-and-configure.sh
```

The script:
1. Scans KServe namespace for InferenceServices
2. Extracts model name and service URL
3. Generates LiteLLM-compatible configuration

### 2. Configuration Format

Models are registered in ConfigMap using **OpenAI-compatible format**:

```yaml
model_list:
  - model_name: qwen3-4b-int4-ov
    litellm_params:
      model: openai/qwen3-4b-int4-ov  # MUST use openai/ prefix
      api_base: http://qwen3-4b-int4-ov-predictor.kserve.svc.ai-stack-cluster/v3
      api_key: dummy  # Required even without auth
      stream: true
      max_retries: 3
```

**Critical Format Requirements:**
- `model` must use `openai/` prefix (not `openvino/`)
- `api_key` required even for endpoints without authentication
- `api_base` must match endpoint type (`/v3` for OVMS, `/v1` for standard)

### 3. Apply Configuration
```bash
kubectl apply -f updated-configmap.yaml
kubectl rollout restart deployment/litellm -n litellm
```

The script automatically:
1. Merges model_list with base LiteLLM config
2. **Detects duplicates** - skips update if models unchanged
3. Applies ConfigMap update
4. Triggers rolling restart of LiteLLM pods
5. Waits for rollout completion
6. Verifies models loaded

### Idempotency & Duplicate Prevention

The script is **idempotent** - safe to run multiple times:

✅ **Duplicate Detection**: Compares current vs. new model list  
✅ **Skip if Unchanged**: Won't restart pods unnecessarily  
✅ **Confirmation Prompt**: Ask before applying if changes detected  
✅ **KServe as Source of Truth**: Always syncs from InferenceServices  

**Example - No Changes:**
```bash
$ ./discover-and-configure.sh
...
ℹ No changes detected - models are already registered

Re-apply configuration anyway? (yes/no): no
ℹ Configuration not changed
```

**Example - Changes Detected:**
```bash
$ ./discover-and-configure.sh
...
ℹ Model configuration to be applied:
  - model_name: new-model
  - model_name: existing-model

Apply this configuration to LiteLLM? (yes/no): yes
✓ ConfigMap updated
```

## Deployment

### Automated (Part of Deploy-All)

When running the full stack deployment:
```bash
cd scripts
./deploy-all.sh
```

Phase 4 automatically:
- Discovers InferenceServices from KServe
- Updates LiteLLM ConfigMap
- Restarts pods with new configuration

### Manual Execution

```bash
cd phase4-model-watcher
./deploy-phase4.sh
```

### Re-run Discovery (After Adding Models)

```bash
cd phase4-model-watcher
./discover-and-configure.sh
```

The script will:
1. Discover all InferenceServices
2. Show current vs. new configuration
3. Prompt for confirmation
4. Apply changes and restart pods

## Verification

### Check Registered Models

```bash
# Port-forward to LiteLLM service
kubectl port-forward -n litellm svc/litellm 4000:4000 &

# List models
curl http://localhost:4000/v1/models \
  -H 'Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef' | jq .
```

Expected output:
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

### Check ConfigMap

```bash
kubectl get configmap litellm-config -n litellm -o yaml | grep -A 10 "model_list:"
```

### Check Pod Logs

```bash
kubectl logs -n litellm deployment/litellm | grep -i model
```

## Rollback

If something goes wrong, roll back the deployment:

```bash
# Undo the last rollout
kubectl rollout undo deployment/litellm -n litellm

# Check status
kubectl rollout status deployment/litellm -n litellm
```

Or restore a specific revision:

```bash
# View revision history
kubectl rollout history deployment/litellm -n litellm

# Rollback to specific revision
kubectl rollout undo deployment/litellm -n litellm --to-revision=2
```

## Why ConfigMap vs. API Registration?

### ❌ API-Based Approach (Deprecated)
```bash
# Old approach (DON'T USE)
curl -X POST http://litellm:4000/model/new \
  -d '{"model_name": "..."}'  # Stored in database
```

**Problems:**
- Not version controlled
- Stored in ephemeral database
- Lost on database reset
- No audit trail
- Requires manual intervention
- Violates GitOps principles

### ✅ ConfigMap-Based Approach (Production Standard)
```yaml
# New approach (USE THIS)
apiVersion: v1
kind: ConfigMap
data:
  config.yaml: |
    model_list:
      - model_name: qwen3-4b
```

**Benefits:**
- Version controlled via Kubernetes
- Declarative and reproducible
- Survives database resets
- Clear audit trail (ConfigMap revisions)
- Automated via kubectl
- Follows GitOps best practices
- Easy rollback

## Migration from Old Approach

If you previously used the API-based registration:

1. **Clean up old resources**:
   ```bash
   kubectl delete namespace model-watcher
   ```

2. **Run new discovery script**:
   ```bash
   cd phase4-model-watcher
   ./discover-and-configure.sh
   ```

3. **Verify models registered**:
   ```bash
   kubectl port-forward -n litellm svc/litellm 4000:4000 &
   curl http://localhost:4000/v1/models -H 'Authorization: Bearer sk-...'
   ```

## Files

### Production Scripts (USE THESE)
- **`discover-and-configure.sh`**: Main discovery and registration script (GitOps)
- **`deploy-phase4.sh`**: Automated deployment wrapper

### Deprecated Scripts (DON'T USE - Kept for Reference)
- ~~`manage-litellm-models.py`~~: Old API-based registration (anti-pattern)
- ~~`deploy-phase4-job.sh`~~: Kubernetes Job version of API registration
- ~~`controllers/model_watcher.py`~~: Legacy Python watcher

## Troubleshooting

### Models Not Showing Up

1. Check if ConfigMap updated:
   ```bash
   kubectl get configmap litellm-config -n litellm -o yaml
   ```

2. Check if pods restarted:
   ```bash
   kubectl get pods -n litellm
   ```

3. Check pod logs for errors:
   ```bash
   kubectl logs -n litellm deployment/litellm | grep -i error
   ```

### "No changes detected" But I Added a Model

This is **expected behavior** when:
- You run the script multiple times without changing InferenceServices
- The script is idempotent - it won't re-apply identical configuration

To force a re-apply:
```bash
./discover-and-configure.sh
# When prompted "Re-apply configuration anyway?", answer: yes
```

Or manually edit the ConfigMap:
```bash
kubectl edit configmap litellm-config -n litellm
```

### Models Disappear After Running Script

**Current behavior**: The script uses **KServe as the source of truth**.

- ✅ Models from InferenceServices are **always included**
- ⚠️ Manually-added models to ConfigMap are **replaced**

**Workarounds:**
1. **Recommended**: Deploy all models as InferenceServices in KServe
2. **Alternative**: Use separate namespace for non-KServe models
3. **Manual**: Edit ConfigMap directly and don't re-run discovery script

**Future enhancement**: Preserve manually-configured models during merge

### "LLM Provider NOT provided" Error

You're using the wrong model prefix. Must use `openai/` not `openvino/`:

```yaml
# WRONG:
model: openvino/qwen3-4b-int4-ov

# CORRECT:
model: openai/qwen3-4b-int4-ov
```

### Connection Reset by Peer

This is caused by Istio mTLS. Use port-forward for testing:

```bash
kubectl port-forward -n litellm svc/litellm 4000:4000
```

## Next Steps

After Phase 4 completes successfully:

1. **Verify models**: Check `/v1/models` endpoint
2. **Test inference**: Send test requests
3. **Run Phase 5**: Deploy optimization and load testing

```bash
cd ../phase5-optimization
./deploy-phase5.sh
```

## Support

For issues or questions:
1. Check this README
2. Review logs: `kubectl logs -n litellm deployment/litellm`
3. Verify ConfigMap: `kubectl get cm litellm-config -n litellm -o yaml`
4. Check InferenceServices: `kubectl get inferenceservices -n kserve`
