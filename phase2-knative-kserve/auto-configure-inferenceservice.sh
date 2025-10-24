#!/bin/bash
set -e

# Auto-configure InferenceService based on available node resources
# This script detects available CPU and sets appropriate replica limits

echo "================================================"
echo "KServe InferenceService Auto-Configuration"
echo "================================================"
echo ""

# Get available CPU cores from the node
TOTAL_CPUS=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}')
ALLOCATABLE_CPUS_RAW=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}')

# Convert millicores to cores if needed (e.g., "47400m" -> "47")
if [[ "$ALLOCATABLE_CPUS_RAW" == *"m" ]]; then
    ALLOCATABLE_CPUS=$((${ALLOCATABLE_CPUS_RAW%m} / 1000))
else
    ALLOCATABLE_CPUS=$ALLOCATABLE_CPUS_RAW
fi

echo "Node Resources:"
echo "  Total CPUs: ${TOTAL_CPUS}"
echo "  Allocatable CPUs: ${ALLOCATABLE_CPUS} cores (${ALLOCATABLE_CPUS_RAW})"
echo ""

# Each model pod needs 8 CPU cores (request) and can use up to 32 (limit)
# Calculate max replicas based on available CPUs
CPU_PER_POD=8
MAX_REPLICAS=$((ALLOCATABLE_CPUS / CPU_PER_POD))

# Ensure at least 1 replica, max 10 for practical limits
if [ "$MAX_REPLICAS" -lt 1 ]; then
    echo "⚠️  WARNING: Only ${ALLOCATABLE_CPUS} CPUs available, need ${CPU_PER_POD} minimum"
    echo "⚠️  Setting maxReplicas=1 but pod may not start without enough CPU"
    MAX_REPLICAS=1
elif [ "$MAX_REPLICAS" -gt 10 ]; then
    echo "✅ High CPU availability detected, capping at 10 replicas"
    MAX_REPLICAS=10
fi

echo "Auto-Configuration:"
echo "  CPU per pod (request): ${CPU_PER_POD} cores"
echo "  CPU per pod (limit): 32 cores"
echo "  Calculated max replicas: ${MAX_REPLICAS}"
echo ""

# Determine minReplicas
if [ "$MAX_REPLICAS" -ge 2 ]; then
    MIN_REPLICAS=1
else
    MIN_REPLICAS=1
fi

# Apply the InferenceService with dynamic values
echo "Deploying InferenceService with:"
echo "  minReplicas: ${MIN_REPLICAS}"
echo "  maxReplicas: ${MAX_REPLICAS}"
echo ""

# Check if InferenceService already exists
if kubectl get inferenceservice qwen3-4b-int4-ov -n kserve &>/dev/null; then
    echo "InferenceService already exists. Updating replica limits..."
    kubectl patch inferenceservice qwen3-4b-int4-ov -n kserve --type=merge \
        -p "{\"spec\":{\"predictor\":{\"minReplicas\":${MIN_REPLICAS},\"maxReplicas\":${MAX_REPLICAS}}}}"
    
    # Update annotations
    kubectl annotate inferenceservice qwen3-4b-int4-ov -n kserve \
        autoscaling.knative.dev/min-scale="${MIN_REPLICAS}" \
        autoscaling.knative.dev/max-scale="${MAX_REPLICAS}" \
        --overwrite
    
    echo "✅ InferenceService updated successfully"
else
    echo "Creating new InferenceService..."
    
    # Create temporary manifest with dynamic values
    cat > /tmp/inferenceservice-auto.yaml <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen3-4b-int4-ov
  namespace: kserve
  annotations:
    # Knative autoscaling annotations - optimized for production workloads
    autoscaling.knative.dev/min-scale: "${MIN_REPLICAS}"
    autoscaling.knative.dev/max-scale: "${MAX_REPLICAS}"
    
    # Dual-metric autoscaling: concurrency + CPU
    autoscaling.knative.dev/target: "10"
    autoscaling.knative.dev/metric: "cpu"
    autoscaling.knative.dev/target-utilization-percentage: "70"
    autoscaling.knative.dev/class: "kpa.autoscaling.knative.dev"
    
    # Scaling behavior tuning
    autoscaling.knative.dev/scale-down-delay: "30s"
    autoscaling.knative.dev/window: "60s"
    autoscaling.knative.dev/panic-window-percentage: "10"
    autoscaling.knative.dev/panic-threshold-percentage: "200"
    
    # Istio sidecar
    sidecar.istio.io/inject: "true"
    serving.kserve.io/deploymentMode: "Serverless"
spec:
  predictor:
    minReplicas: ${MIN_REPLICAS}
    maxReplicas: ${MAX_REPLICAS}
    scaleTarget: 10
    scaleMetric: concurrency
    model:
      runtime: kserve-openvino-hf
      modelFormat:
        name: huggingface
      args:
        - --source_model=OpenVINO/Qwen3-4B-int4-ov
        - --model_repository_path=/tmp
        - --task=text_generation
        - --target_device=CPU
      resources:
        requests:
          cpu: "${CPU_PER_POD}"
          memory: "16Gi"
        limits:
          cpu: "32"
          memory: "64Gi"
EOF

    kubectl apply -f /tmp/inferenceservice-auto.yaml
    echo "✅ InferenceService created successfully"
    rm /tmp/inferenceservice-auto.yaml
fi

echo ""
echo "================================================"
echo "Configuration Summary"
echo "================================================"
echo "Node CPUs: ${ALLOCATABLE_CPUS} allocatable (${TOTAL_CPUS} total)"
echo "Model Replicas: ${MIN_REPLICAS} (min) to ${MAX_REPLICAS} (max)"
echo "CPU per replica: ${CPU_PER_POD} cores (request), 32 cores (limit)"
echo "Total CPU when fully scaled: $((MAX_REPLICAS * CPU_PER_POD)) cores"
echo ""
echo "Autoscaling: Dual-metric (Concurrency + CPU)"
echo "  - Scales up when >10 concurrent OR >70% CPU"
echo "  - Scales down after 30s of low load"
echo "================================================"
