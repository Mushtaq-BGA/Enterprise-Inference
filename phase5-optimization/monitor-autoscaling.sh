#!/bin/bash

# Monitor KServe autoscaling behavior
# Shows real-time replica count and CPU usage

echo "================================================"
echo "KServe Model Autoscaling Monitor"
echo "================================================"
echo "Monitoring: qwen3-4b-int4-ov"
echo "Press Ctrl+C to stop"
echo "================================================"
echo ""

while true; do
    # Get current time
    TIMESTAMP=$(date '+%H:%M:%S')
    
    # Get pod count
    POD_COUNT=$(kubectl get pods -n kserve -l serving.kserve.io/inferenceservice=qwen3-4b-int4-ov --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    
    # Get CPU usage
    CPU_USAGE=$(kubectl top pods -n kserve -l serving.kserve.io/inferenceservice=qwen3-4b-int4-ov --no-headers 2>/dev/null | awk '{sum+=$2} END {print sum}' | sed 's/m$//')
    
    if [ -z "$CPU_USAGE" ]; then
        CPU_USAGE="0"
    fi
    
    # Convert millicores to cores
    if [ "$CPU_USAGE" -ge 1000 ]; then
        CPU_CORES=$(echo "scale=2; $CPU_USAGE / 1000" | bc)
        CPU_DISPLAY="${CPU_CORES} cores"
    else
        CPU_DISPLAY="${CPU_USAGE}m"
    fi
    
    # Get configured limits
    CONFIG=$(kubectl get inferenceservice qwen3-4b-int4-ov -n kserve -o jsonpath='{.spec.predictor.minReplicas}/{.spec.predictor.maxReplicas}' 2>/dev/null)
    
    # Display status
    printf "[%s] Replicas: %d (min/max: %s) | CPU: %s\n" "$TIMESTAMP" "$POD_COUNT" "$CONFIG" "$CPU_DISPLAY"
    
    sleep 5
done
