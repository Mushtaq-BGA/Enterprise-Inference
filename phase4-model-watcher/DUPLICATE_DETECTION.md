# Duplicate Detection & Idempotency

## Overview

The `discover-and-configure.sh` script implements **intelligent duplicate detection** to prevent unnecessary ConfigMap updates and pod restarts.

## How It Works

```
┌─────────────────────────────────────┐
│ 1. Discover InferenceServices       │
│    from KServe namespace             │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 2. Get Current ConfigMap             │
│    (if exists)                       │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 3. Compare Model Lists               │
│    Current vs. Discovered            │
└──────────────┬──────────────────────┘
               │
               ├─────────────────────┐
               │                     │
         No Changes             Changes Detected
               │                     │
               ▼                     ▼
┌─────────────────────┐   ┌──────────────────────┐
│ Skip Update         │   │ Prompt for           │
│ (idempotent)        │   │ Confirmation         │
└─────────────────────┘   └──────┬───────────────┘
                                 │
                           User says "yes"
                                 │
                                 ▼
                      ┌──────────────────────┐
                      │ Apply ConfigMap      │
                      │ Restart Pods         │
                      └──────────────────────┘
```

## Comparison Logic

### Step 1: Extract Current Models
```bash
# From existing ConfigMap
kubectl get configmap litellm-config -n litellm -o yaml
  ↓
Extract all model_name entries
  ↓
Current: [model-a, model-b, model-c]
```

### Step 2: Discover New Models
```bash
# From KServe InferenceServices
kubectl get inferenceservices -n kserve
  ↓
Extract all model names
  ↓
Discovered: [model-a, model-b, model-c]
```

### Step 3: Compare Lists
```bash
if [ "$CURRENT" = "$DISCOVERED" ]; then
  echo "No changes detected"
  exit 0
fi
```

## Behavior Examples

### Example 1: No Changes (Idempotent)
```bash
$ ./discover-and-configure.sh

ℹ Discovering InferenceServices...
✓ Discovered 1 model(s)
  - qwen3-4b-int4-ov

ℹ Reading current configuration...
ℹ No changes detected - models are already registered

Re-apply configuration anyway? (yes/no): no
ℹ Configuration not changed
```

**Result:** No pod restarts, no ConfigMap updates.

---

### Example 2: New Model Added
```bash
# Step 1: Initial state
Current models: [qwen3-4b-int4-ov]

# Step 2: Deploy new InferenceService
kubectl apply -f new-model.yaml

# Step 3: Run discovery
$ ./discover-and-configure.sh

ℹ Discovering InferenceServices...
✓ Discovered 2 model(s)
  - qwen3-4b-int4-ov
  - llama-7b-int4-ov  ← NEW

ℹ Model configuration to be applied:
---
model_list:
  - model_name: qwen3-4b-int4-ov
  - model_name: llama-7b-int4-ov
---

Apply this configuration to LiteLLM? (yes/no): yes
✓ ConfigMap updated
✓ LiteLLM restarted
```

**Result:** ConfigMap updated, pods restarted with new model.

---

### Example 3: Model Removed
```bash
# Step 1: Initial state
Current models: [qwen3-4b-int4-ov, llama-7b-int4-ov]

# Step 2: Delete InferenceService
kubectl delete inferenceservice llama-7b-int4-ov -n kserve

# Step 3: Run discovery
$ ./discover-and-configure.sh

ℹ Discovering InferenceServices...
✓ Discovered 1 model(s)
  - qwen3-4b-int4-ov
  (llama-7b-int4-ov removed)

Apply this configuration to LiteLLM? (yes/no): yes
✓ ConfigMap updated (model removed)
✓ LiteLLM restarted
```

**Result:** ConfigMap updated, removed model no longer accessible.

---

## Implementation Details

### Duplicate Detection Code
```bash
# Extract current model names (sorted)
CURRENT_MODEL_LIST=$(echo "$CURRENT_CONFIGMAP" | \
  grep -A 100 "^model_list:" | \
  grep "model_name:" | \
  awk '{print $3}' | \
  sort)

# Extract discovered model names (sorted)
NEW_MODEL_LIST=$(grep "model_name:" "$MODEL_LIST_YAML" | \
  awk '{print $3}' | \
  sort)

# Compare
if [ "$CURRENT_MODEL_LIST" = "$NEW_MODEL_LIST" ]; then
    print_info "No changes detected - models are already registered"
    # Prompt to re-apply or exit
fi
```

### Automatic Mode (CI/CD)
For automated deployments, pipe "yes" to auto-confirm:
```bash
echo "yes" | ./discover-and-configure.sh
```

This always applies changes if detected (or skips if no changes).

---

## Benefits

### ✅ Prevents Unnecessary Restarts
- Avoids downtime when models haven't changed
- Saves time in CI/CD pipelines
- Reduces Kubernetes API load

### ✅ Safe to Run Repeatedly
- No side effects from multiple runs
- Idempotent behavior
- Predictable outcomes

### ✅ Clear Feedback
- Shows what will change before applying
- Prompts for confirmation
- Logs all actions

### ✅ KServe as Source of Truth
- Configuration syncs from InferenceServices
- No manual model list maintenance
- Self-healing - re-run to sync

---

## Limitations

### ⚠️ Overwrites Manual Changes
**Current behavior**: Manually-added models in ConfigMap are **replaced**.

**Example:**
```yaml
# ConfigMap has:
model_list:
  - model_name: qwen3-4b-int4-ov  # From KServe
  - model_name: external-api      # Manually added

# After running script:
model_list:
  - model_name: qwen3-4b-int4-ov  # From KServe
  # external-api is GONE!
```

**Workaround:**
1. Deploy all models as InferenceServices (recommended)
2. Use separate LiteLLM instance for external models
3. Don't re-run discovery script after manual edits

**Future Enhancement:**
Merge KServe models + manually-configured models:
```bash
# Proposed behavior:
# 1. Discover from KServe
# 2. Extract manually-added models (not in KServe)
# 3. Merge both lists
# 4. Apply combined configuration
```

---

## Testing Duplicate Detection

### Test 1: Run Twice (No Changes)
```bash
# First run
./discover-and-configure.sh
# Answer: yes

# Second run immediately
./discover-and-configure.sh
# Expected: "No changes detected"
```

### Test 2: Add Model and Re-run
```bash
# Deploy new model
kubectl apply -f new-model.yaml

# Wait for ready
kubectl wait --for=condition=Ready inferenceservice/new-model -n kserve

# Run discovery
./discover-and-configure.sh
# Expected: Shows new model, prompts for confirmation
```

### Test 3: Force Re-apply
```bash
./discover-and-configure.sh
# When "No changes detected", answer: yes to "Re-apply anyway?"
# Expected: Restarts pods even without changes
```

---

## Automated Deployment

In `deploy-phase4.sh`, the script uses auto-confirm:
```bash
echo "yes" | ./discover-and-configure.sh
```

This ensures:
- No interactive prompts (CI/CD friendly)
- Always applies if changes detected
- Skips if no changes (idempotent)

---

## Conclusion

The duplicate detection makes Phase 4 **production-ready**:

- ✅ Idempotent (safe to run multiple times)
- ✅ Efficient (skips unnecessary restarts)
- ✅ Predictable (clear change detection)
- ✅ GitOps-friendly (declarative sync)

**KServe InferenceServices are the source of truth** - the script always syncs LiteLLM to match KServe state.
