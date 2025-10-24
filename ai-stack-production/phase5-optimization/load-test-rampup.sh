#!/bin/bash
# Ramp-up load test - Gradually increase concurrency with realistic payloads
set -euo pipefail

LITELLM_HOST="${LITELLM_HOST:-litellm.aistack.local}"
LITELLM_PORT="${LITELLM_PORT:-30080}"
API_KEY="${API_KEY:-sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef}"
MODEL="${MODEL:-qwen3-4b-int4-ov}"
PAYLOAD_TYPE="${PAYLOAD_TYPE:-simple}"  # simple, small, medium, large, rag

# Test levels - set EXTENDED_TEST=true to run 750 and 1000 concurrent users
EXTENDED_TEST="${EXTENDED_TEST:-false}"

# Optional monitoring - set MONITOR=true to run autoscaling monitor in background
MONITOR="${MONITOR:-false}"
MONITOR_PID=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/test-data"

# Start optional monitoring
if [ "$MONITOR" = "true" ] && [ -f "$SCRIPT_DIR/monitor-autoscaling.sh" ]; then
    echo "Starting autoscaling monitor in background..."
    "$SCRIPT_DIR/monitor-autoscaling.sh" > /tmp/autoscaling-monitor.log 2>&1 &
    MONITOR_PID=$!
    echo "Monitor PID: $MONITOR_PID (logs: /tmp/autoscaling-monitor.log)"
    sleep 2
fi

# Cleanup function
cleanup() {
    if [ -n "$MONITOR_PID" ]; then
        echo "Stopping autoscaling monitor..."
        kill $MONITOR_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "========================================="
echo "LiteLLM Load Test - Ramp-up Concurrency"
echo "========================================="
echo "Payload Type: $PAYLOAD_TYPE"
if [ "$MONITOR" = "true" ]; then
    echo "Monitoring: Enabled (logs in /tmp/autoscaling-monitor.log)"
fi
if [ "$EXTENDED_TEST" = "true" ]; then
    echo "Mode: Extended Test"
    echo "Testing with increasing concurrency:"
    echo "  100 → 250 → 500 → 750 → 1000"
else
    echo "Mode: Standard Test (up to 500 concurrent)"
    echo "Testing with increasing concurrency:"
    echo "  100 → 250 → 500"
    echo ""
    echo "For extended test (750, 1000), run with:"
    echo "  EXTENDED_TEST=true ./load-test-rampup.sh"
fi
echo "========================================="

# Create test payload based on type
create_payload() {
    local prompt=""
    local max_tokens=100
    
    case "$PAYLOAD_TYPE" in
        simple)
            prompt="Test message"
            max_tokens=30
            ;;
        small)
            if [ -f "$DATA_DIR/payloads_small.json" ]; then
                prompt=$(jq -r '.[0].content' "$DATA_DIR/payloads_small.json" | head -c 500)
                max_tokens=100
            else
                prompt="Write a brief summary of the benefits of exercise."
                max_tokens=100
            fi
            ;;
        medium)
            if [ -f "$DATA_DIR/payloads_medium.json" ]; then
                prompt=$(jq -r '.[0].content' "$DATA_DIR/payloads_medium.json" | head -c 2000)
                max_tokens=200
            else
                prompt="Explain machine learning concepts including neural networks, layers, and backpropagation."
                max_tokens=200
            fi
            ;;
        large)
            if [ -f "$DATA_DIR/payloads_large.json" ]; then
                prompt=$(jq -r '.[0].content' "$DATA_DIR/payloads_large.json" | head -c 6000)
                max_tokens=300
            else
                prompt="Design a microservices architecture for an e-commerce platform. Include details about service decomposition, communication patterns, data storage, and scaling strategies."
                max_tokens=300
            fi
            ;;
        rag)
            if [ -f "$DATA_DIR/payloads_rag.json" ]; then
                prompt=$(jq -r '.[0].content' "$DATA_DIR/payloads_rag.json" | head -c 12000)
                max_tokens=400
            else
                prompt="Context: [Large code documentation and examples...] Question: Explain the authentication flow and scaling strategy based on the provided context."
                max_tokens=400
            fi
            ;;
    esac
    
    # Create JSON payload properly
    jq -n --arg model "$MODEL" --arg content "$prompt" --argjson max_tokens "$max_tokens" '{
        model: $model,
        messages: [{role: "user", content: $content}],
        max_tokens: $max_tokens
    }'
}

# Test payload
PAYLOAD=$(create_payload)

echo "$PAYLOAD" > /tmp/rampup-payload.json

# Function to run load test
run_test() {
    local concurrency=$1
    local duration=$2
    
    echo ""
    echo "========================================="
    echo "Testing with $concurrency concurrent users for ${duration}s"
    echo "========================================="
    
    if command -v hey &> /dev/null; then
        hey -z ${duration}s \
            -c $concurrency \
            -m POST \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -H "Host: $LITELLM_HOST" \
            -D /tmp/rampup-payload.json \
            "http://$LITELLM_HOST:$LITELLM_PORT/v1/chat/completions" | \
            grep -E "(Requests/sec|Total:|Latency|Status)"
    elif command -v wrk &> /dev/null; then
        # Create wrk Lua script
        cat > /tmp/rampup-test.lua <<LUA_SCRIPT
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.headers["Authorization"] = "Bearer $API_KEY"
wrk.headers["Host"] = "$LITELLM_HOST"

-- Read payload from file
local file = io.open("/tmp/rampup-payload.json", "r")
wrk.body = file:read("*all")
file:close()
LUA_SCRIPT
        
        wrk -t4 -c$concurrency -d${duration}s \
            --latency \
            -s /tmp/rampup-test.lua \
            "http://$LITELLM_HOST:$LITELLM_PORT/v1/chat/completions"
    else
        echo "No load testing tool found (hey or wrk), skipping test"
    fi
    
    echo ""
    # Get resource consumption with proper unit conversion
    LITELLM_CPU_M=$(kubectl top pods -n litellm -l app=litellm --no-headers 2>/dev/null | awk '{sum+=$2} END {print sum}' | sed 's/m//' || echo "0")
    LITELLM_MEM_MI=$(kubectl top pods -n litellm -l app=litellm --no-headers 2>/dev/null | awk '{sum+=$3} END {print sum}' | sed 's/Mi//' || echo "0")
    LITELLM_REPLICAS=$(kubectl get pods -n litellm -l app=litellm --no-headers 2>/dev/null | wc -l)
    
    # Convert to cores and GB
    LITELLM_CPU_CORES=$(echo "scale=2; $LITELLM_CPU_M / 1000" | bc)
    LITELLM_MEM_GB=$(echo "scale=2; $LITELLM_MEM_MI / 1024" | bc)
    
    # KServe metrics
    KSERVE_CPU_M=$(kubectl top pods -n kserve --no-headers 2>/dev/null | grep predictor | awk '{sum+=$2} END {print sum}' | sed 's/m//' || echo "0")
    KSERVE_MEM_MI=$(kubectl top pods -n kserve --no-headers 2>/dev/null | grep predictor | awk '{sum+=$3} END {print sum}' | sed 's/Mi//' || echo "0")
    KSERVE_REPLICAS=$(kubectl get pods -n kserve --no-headers 2>/dev/null | grep predictor | grep Running | wc -l)
    
    # Convert KServe CPU - show millicores if < 100m
    if [ "$KSERVE_CPU_M" -gt 0 ] && [ "$KSERVE_CPU_M" -lt 100 ]; then
        KSERVE_CPU_DISPLAY="${KSERVE_CPU_M}m"
    elif [ "$KSERVE_CPU_M" -ge 100 ]; then
        KSERVE_CPU_CORES=$(echo "scale=2; $KSERVE_CPU_M / 1000" | bc)
        KSERVE_CPU_DISPLAY="${KSERVE_CPU_CORES} cores"
    else
        KSERVE_CPU_DISPLAY="N/A"
    fi
    
    KSERVE_MEM_GB=$(echo "scale=2; $KSERVE_MEM_MI / 1024" | bc)
    
    echo ""
    printf "╔════════════════════╦═══════════╦════════════╦═══════════╗\n"
    printf "║ %-18s ║ %-9s ║ %-10s ║ %-9s ║\n" "Component" "Replicas" "CPU" "Memory"
    printf "╠════════════════════╬═══════════╬════════════╬═══════════╣\n"
    printf "║ %-18s ║ %-9s ║ %-10s ║ %-9s ║\n" "LiteLLM Proxy" "$LITELLM_REPLICAS" "${LITELLM_CPU_CORES} cores" "${LITELLM_MEM_GB} GB"
    printf "║ %-18s ║ %-9s ║ %-10s ║ %-9s ║\n" "KServe Model" "$KSERVE_REPLICAS" "$KSERVE_CPU_DISPLAY" "${KSERVE_MEM_GB} GB"
    printf "╚════════════════════╩═══════════╩════════════╩═══════════╝\n"
    echo ""
    
    echo "Waiting 30s for metrics to stabilize..."
    sleep 30
}

# Ramp up gradually - standard test (100, 250, 500)
run_test 100 60
run_test 250 60
run_test 500 90

# Extended test levels (750, 1000) - only run if EXTENDED_TEST=true
if [ "$EXTENDED_TEST" = "true" ]; then
    echo ""
    echo "========================================="
    echo "Running Extended Test Levels"
    echo "========================================="
    run_test 750 90
    run_test 1000 120
fi

# Cleanup
rm -f /tmp/rampup-payload.json /tmp/rampup-test.lua

echo ""
echo "========================================="
echo "Ramp-up Test Complete - Final Status"
echo "========================================="

# Get final resource metrics
LITELLM_CPU_M=$(kubectl top pods -n litellm -l app=litellm --no-headers 2>/dev/null | awk '{sum+=$2} END {print sum}' | sed 's/m//' || echo "0")
LITELLM_MEM_MI=$(kubectl top pods -n litellm -l app=litellm --no-headers 2>/dev/null | awk '{sum+=$3} END {print sum}' | sed 's/Mi//' || echo "0")
LITELLM_REPLICAS=$(kubectl get pods -n litellm -l app=litellm --no-headers 2>/dev/null | wc -l)

LITELLM_CPU_CORES=$(echo "scale=2; $LITELLM_CPU_M / 1000" | bc)
LITELLM_MEM_GB=$(echo "scale=2; $LITELLM_MEM_MI / 1024" | bc)

KSERVE_CPU_M=$(kubectl top pods -n kserve --no-headers 2>/dev/null | grep predictor | awk '{sum+=$2} END {print sum}' | sed 's/m//' || echo "0")
KSERVE_MEM_MI=$(kubectl top pods -n kserve --no-headers 2>/dev/null | grep predictor | awk '{sum+=$3} END {print sum}' | sed 's/Mi//' || echo "0")
KSERVE_REPLICAS=$(kubectl get pods -n kserve --no-headers 2>/dev/null | grep predictor | grep Running | wc -l)

if [ "$KSERVE_CPU_M" -gt 0 ] && [ "$KSERVE_CPU_M" -lt 100 ]; then
    KSERVE_CPU_DISPLAY="${KSERVE_CPU_M}m"
elif [ "$KSERVE_CPU_M" -ge 100 ]; then
    KSERVE_CPU_CORES=$(echo "scale=2; $KSERVE_CPU_M / 1000" | bc)
    KSERVE_CPU_DISPLAY="${KSERVE_CPU_CORES} cores"
else
    KSERVE_CPU_DISPLAY="N/A"
fi

KSERVE_MEM_GB=$(echo "scale=2; $KSERVE_MEM_MI / 1024" | bc)

# HPA status
HPA_MIN=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "N/A")
HPA_MAX=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "N/A")
HPA_CURRENT=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "N/A")
HPA_CPU=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.status.currentMetrics[?(@.type=="Resource")].resource.current.averageUtilization}' 2>/dev/null | head -1 || echo "N/A")

# Determine concurrency range based on test mode
if [ "$EXTENDED_TEST" = "true" ]; then
    CONCURRENCY_RANGE="100→1000"
else
    CONCURRENCY_RANGE="100→500"
fi

echo ""
printf "╔════════════════════════════════════╦═══════════════════╗\n"
printf "║ %-34s ║ %-17s ║\n" "METRIC" "VALUE"
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "Test Type" "Ramp-up"
printf "║ %-34s ║ %-17s ║\n" "Model" "$MODEL"
printf "║ %-34s ║ %-17s ║\n" "Payload Type" "$PAYLOAD_TYPE"
printf "║ %-34s ║ %-17s ║\n" "Concurrency Tested" "$CONCURRENCY_RANGE"
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "LITELLM PROXY (Final State)" ""
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "Replicas (Current/Min/Max)" "$LITELLM_REPLICAS / $HPA_MIN / $HPA_MAX"
printf "║ %-34s ║ %-17s ║\n" "Current CPU Utilization" "${HPA_CPU}%"
printf "║ %-34s ║ %-17s ║\n" "Total CPU Usage" "${LITELLM_CPU_CORES} cores"
printf "║ %-34s ║ %-17s ║\n" "Total Memory Usage" "${LITELLM_MEM_GB} GB"
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "MODEL SERVING (KServe)" ""
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "Model Replicas" "$KSERVE_REPLICAS"
printf "║ %-34s ║ %-17s ║\n" "Total CPU Usage" "$KSERVE_CPU_DISPLAY"
printf "║ %-34s ║ %-17s ║\n" "Total Memory Usage" "${KSERVE_MEM_GB} GB"
printf "╚════════════════════════════════════╩═══════════════════╝\n"
echo ""
echo "Autoscaling Performance:"
kubectl get hpa -n litellm
echo ""
echo "Pod Status:"
kubectl get pods -n litellm -l app=litellm
echo ""
