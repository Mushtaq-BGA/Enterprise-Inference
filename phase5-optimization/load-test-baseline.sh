#!/bin/bash
# Load test script - Baseline performance with realistic payloads
set -euo pipefail

# Configuration
LITELLM_HOST="${LITELLM_HOST:-litellm.aistack.local}"
LITELLM_PORT="${LITELLM_PORT:-30080}"
API_KEY="${API_KEY:-sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef}"
MODEL="${MODEL:-qwen3-4b-int4-ov}"

# Test parameters
DURATION="${DURATION:-60}"  # seconds
CONCURRENCY="${CONCURRENCY:-100}"
RATE="${RATE:-1000}"  # requests per second (wrk2 requires this)
SAMPLE_REQUESTS="${SAMPLE_REQUESTS:-10}"  # Number of requests to sample for TTFT

# Payload configuration
PAYLOAD_TYPE="${PAYLOAD_TYPE:-simple}"  # simple, small, medium, large, rag
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/test-data"

# Optional monitoring - set MONITOR=true to run autoscaling monitor in background
MONITOR="${MONITOR:-false}"
MONITOR_PID=""

# Start optional monitoring
if [ "$MONITOR" = "true" ] && [ -f "$SCRIPT_DIR/monitor-autoscaling.sh" ]; then
    echo "Starting autoscaling monitor in background..."
    "$SCRIPT_DIR/monitor-autoscaling.sh" > /tmp/autoscaling-monitor.log 2>&1 &
    MONITOR_PID=$!
    echo "Monitor PID: $MONITOR_PID (logs: /tmp/autoscaling-monitor.log)"
    echo ""
    sleep 2
fi

# Cleanup function
cleanup() {
    if [ -n "$MONITOR_PID" ]; then
        echo ""
        echo "Stopping autoscaling monitor..."
        kill $MONITOR_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "========================================="
echo "LiteLLM Load Test - Baseline Performance"
echo "========================================="
echo "Target: http://$LITELLM_HOST:$LITELLM_PORT"
echo "Model: $MODEL"
echo "Duration: ${DURATION}s"
echo "Concurrency: $CONCURRENCY"
echo "Rate: $RATE req/s"
echo "Payload Type: $PAYLOAD_TYPE"
if [ "$MONITOR" = "true" ]; then
    echo "Monitoring: Enabled (logs in /tmp/autoscaling-monitor.log)"
fi
echo "========================================="

# Create test payload based on type
create_payload() {
    local prompt=""
    local max_tokens=100
    local payload_desc="Simple test"
    
    case "$PAYLOAD_TYPE" in
        simple)
            prompt="Test message"
            max_tokens=30
            payload_desc="Simple (5 tokens)"
            ;;
        small)
            if [ -f "$DATA_DIR/payloads_small.json" ]; then
                prompt=$(jq -r '.[0].content' "$DATA_DIR/payloads_small.json" | head -c 500)
                max_tokens=100
                payload_desc="Small (50-150 input, 100 output tokens)"
            else
                prompt="Write a brief summary of the benefits of exercise for overall health and wellness."
                max_tokens=100
                payload_desc="Small (synthetic, ~100 total tokens)"
            fi
            ;;
        medium)
            if [ -f "$DATA_DIR/payloads_medium.json" ]; then
                prompt=$(jq -r '.[0].content' "$DATA_DIR/payloads_medium.json" | head -c 2000)
                max_tokens=200
                payload_desc="Medium (150-500 input, 200 output tokens)"
            else
                prompt="Explain the concept of machine learning and deep learning. Describe how neural networks work, including key components like layers, neurons, activation functions, and backpropagation. Also explain the difference between supervised and unsupervised learning."
                max_tokens=200
                payload_desc="Medium (synthetic, ~400 total tokens)"
            fi
            ;;
        large)
            if [ -f "$DATA_DIR/payloads_large.json" ]; then
                prompt=$(jq -r '.[0].content' "$DATA_DIR/payloads_large.json" | head -c 6000)
                max_tokens=300
                payload_desc="Large (500-1500 input, 300 output tokens)"
            else
                prompt="You are a software architect helping design a new microservices-based system. The system needs to handle user authentication, real-time notifications, data processing pipelines, and a RESTful API. Describe the architecture you would recommend, including service decomposition, communication patterns, data storage strategies, deployment considerations, monitoring and observability, and scaling strategies. Also discuss potential challenges and how to address them."
                max_tokens=300
                payload_desc="Large (synthetic, ~600 total tokens)"
            fi
            ;;
        rag)
            if [ -f "$DATA_DIR/payloads_rag.json" ]; then
                prompt=$(jq -r '.[0].content' "$DATA_DIR/payloads_rag.json" | head -c 12000)
                max_tokens=400
                payload_desc="RAG (1500+ input, 400 output tokens)"
            else
                # Simulate RAG with context
                prompt="Context: You are helping analyze a large codebase. Here is the relevant code and documentation:

[Code snippet 1] - Authentication module handles user login with JWT tokens, session management, and OAuth2 integration.
[Code snippet 2] - Database layer uses PostgreSQL with connection pooling and read replicas for scaling.
[Code snippet 3] - API gateway implements rate limiting, request validation, and route management.
[Documentation] - System architecture follows microservices pattern with event-driven communication.

Question: Based on the code and documentation provided, explain how the authentication flow works from initial login through token validation, and describe how the system scales to handle high traffic loads. Include specific details about the technologies used."
                max_tokens=400
                payload_desc="RAG (synthetic, ~1800 total tokens)"
            fi
            ;;
        *)
            echo "Unknown payload type: $PAYLOAD_TYPE"
            echo "Valid types: simple, small, medium, large, rag"
            exit 1
            ;;
    esac
    
    # Create JSON payload properly
    # For large payloads, we can enable streaming and other optimizations
    if [ "$PAYLOAD_TYPE" = "large" ] || [ "$PAYLOAD_TYPE" = "rag" ]; then
        # Large payload optimizations
        jq -n --arg model "$MODEL" --arg content "$prompt" --argjson max_tokens "$max_tokens" --arg desc "$payload_desc" '{
            model: $model,
            messages: [{role: "user", content: $content}],
            max_tokens: $max_tokens,
            temperature: 0.7,
            stream: false,
            _payload_desc: $desc
        }'
    else
        # Standard payload
        jq -n --arg model "$MODEL" --arg content "$prompt" --argjson max_tokens "$max_tokens" --arg desc "$payload_desc" '{
            model: $model,
            messages: [{role: "user", content: $content}],
            max_tokens: $max_tokens,
            temperature: 0.7,
            _payload_desc: $desc
        }'
    fi
}

# Create test payload
PAYLOAD=$(create_payload)

# Extract payload description and remove from JSON
PAYLOAD_DESC=$(echo "$PAYLOAD" | jq -r '._payload_desc // "Unknown"')
PAYLOAD=$(echo "$PAYLOAD" | jq 'del(._payload_desc)')

echo "Payload: $PAYLOAD_DESC"
echo ""

# Save payload to temp file
echo "$PAYLOAD" > /tmp/load-test-payload.json

# Check for wrk2 first (preferred), then fall back to other tools
if command -v wrk2 &> /dev/null; then
    echo "Using wrk2 for load testing (constant throughput)..."
    
    # Calculate threads (wrk2 requires connections >= threads)
    THREADS=4
    if [ "$CONCURRENCY" -lt 4 ]; then
        THREADS=$CONCURRENCY
    fi
    
    # Create wrk2 Lua script with payload from file
    cat > /tmp/load-test.lua <<LUA_SCRIPT
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.headers["Authorization"] = "Bearer $API_KEY"
wrk.headers["Host"] = "$LITELLM_HOST"

-- Read payload from file
local file = io.open("/tmp/load-test-payload.json", "r")
wrk.body = file:read("*all")
file:close()
LUA_SCRIPT
    
    wrk2 -t$THREADS -c$CONCURRENCY -d${DURATION}s -R$RATE \
        --latency \
        -s /tmp/load-test.lua \
        "http://$LITELLM_HOST:$LITELLM_PORT/v1/chat/completions"

elif command -v wrk &> /dev/null; then
    echo "Using wrk for load testing..."
    echo "Note: wrk doesn't support constant rate. Consider installing wrk2 for better results."
    
    # Calculate threads
    THREADS=4
    if [ "$CONCURRENCY" -lt 4 ]; then
        THREADS=$CONCURRENCY
    fi
    
    # Create wrk Lua script with payload from file
    cat > /tmp/load-test.lua <<LUA_SCRIPT
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.headers["Authorization"] = "Bearer $API_KEY"
wrk.headers["Host"] = "$LITELLM_HOST"

-- Read payload from file
local file = io.open("/tmp/load-test-payload.json", "r")
wrk.body = file:read("*all")
file:close()
LUA_SCRIPT
    
    wrk -t$THREADS -c$CONCURRENCY -d${DURATION}s \
        --latency \
        -s /tmp/load-test.lua \
        "http://$LITELLM_HOST:$LITELLM_PORT/v1/chat/completions"

elif command -v hey &> /dev/null; then
    echo "Using hey for load testing..."
    hey -z ${DURATION}s \
        -c $CONCURRENCY \
        -m POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "Host: $LITELLM_HOST" \
        -D /tmp/load-test-payload.json \
        "http://$LITELLM_HOST:$LITELLM_PORT/v1/chat/completions"

elif command -v ab &> /dev/null; then
    echo "Using Apache Bench for load testing..."
    ab -n 1000 -c $CONCURRENCY \
        -T "application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Host: $LITELLM_HOST" \
        -p /tmp/load-test-payload.json \
        "http://$LITELLM_HOST:$LITELLM_PORT/v1/chat/completions"

else
    echo "Error: No load testing tool found. Please install one of: wrk2, wrk, hey, ab"
    echo ""
    echo "Install wrk2 (recommended):"
    echo "  cd /tmp && git clone https://github.com/giltene/wrk2.git"
    echo "  cd wrk2 && make && sudo cp wrk /usr/local/bin/wrk2"
    echo ""
    echo "Install wrk:"
    echo "  sudo apt-get install wrk"
    echo ""
    echo "Install hey:"
    echo "  go install github.com/rakyll/hey@latest"
    echo ""
    echo "Install ab:"
    echo "  sudo apt-get install apache2-utils"
    exit 1
fi

# Cleanup
rm -f /tmp/load-test-payload.json /tmp/load-test.lua

echo ""
echo "========================================="
echo "Collecting Detailed Metrics"
echo "========================================="

# Sample TTFT and tokens/sec from actual requests
echo "Sampling $SAMPLE_REQUESTS requests for TTFT and throughput..."
TTFT_TOTAL=0
TOKENS_TOTAL=0
REQUESTS_SAMPLED=0
TOTAL_TIME=0

for i in $(seq 1 $SAMPLE_REQUESTS); do
    START_TIME=$(date +%s.%N)
    RESPONSE=$(curl -s \
        -X POST "http://$LITELLM_HOST:$LITELLM_PORT/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "Host: $LITELLM_HOST" \
        -d "$PAYLOAD" 2>/dev/null)
    END_TIME=$(date +%s.%N)
    
    # Calculate total time
    REQ_TIME=$(echo "$END_TIME - $START_TIME" | bc)
    
    # Extract tokens from response
    COMPLETION_TOKENS=$(echo "$RESPONSE" | grep -o '"completion_tokens":[0-9]*' | cut -d: -f2 | head -1)
    PROMPT_TOKENS=$(echo "$RESPONSE" | grep -o '"prompt_tokens":[0-9]*' | cut -d: -f2 | head -1)
    
    if [ -n "$COMPLETION_TOKENS" ] && [ "$COMPLETION_TOKENS" -gt 0 ]; then
        TTFT_TOTAL=$(echo "$TTFT_TOTAL + $REQ_TIME" | bc)
        TOKENS_TOTAL=$((TOKENS_TOTAL + COMPLETION_TOKENS))
        TOTAL_TIME=$(echo "$TOTAL_TIME + $REQ_TIME" | bc)
        REQUESTS_SAMPLED=$((REQUESTS_SAMPLED + 1))
    fi
done

# Calculate averages
if [ $REQUESTS_SAMPLED -gt 0 ]; then
    # TTFT in seconds, then convert to milliseconds
    AVG_TTFT_SEC=$(echo "scale=3; $TTFT_TOTAL / $REQUESTS_SAMPLED" | bc)
    AVG_TTFT_MS=$(echo "scale=0; $AVG_TTFT_SEC * 1000" | bc)
    AVG_TOKENS=$(echo "scale=1; $TOKENS_TOTAL / $REQUESTS_SAMPLED" | bc)
    # Output tokens per second = total completion tokens / total time
    # Note: This includes TTFT overhead in the timing
    TOKENS_PER_SEC=$(echo "scale=2; $TOKENS_TOTAL / $TOTAL_TIME" | bc)
else
    AVG_TTFT_MS="N/A"
    AVG_TOKENS="N/A"
    TOKENS_PER_SEC="N/A"
fi

# Get resource consumption
echo "Collecting resource metrics..."

# LiteLLM resource usage
LITELLM_CPU_M=$(kubectl top pods -n litellm -l app=litellm --no-headers 2>/dev/null | awk '{sum+=$2} END {print sum}' | sed 's/m//' || echo "0")
LITELLM_MEM_MI=$(kubectl top pods -n litellm -l app=litellm --no-headers 2>/dev/null | awk '{sum+=$3} END {print sum}' | sed 's/Mi//' || echo "0")
LITELLM_REPLICAS=$(kubectl get pods -n litellm -l app=litellm --no-headers 2>/dev/null | wc -l)

# Convert CPU millicores to cores (divide by 1000)
LITELLM_CPU_CORES=$(echo "scale=2; $LITELLM_CPU_M / 1000" | bc)
if [ -z "$LITELLM_CPU_CORES" ] || [ "$LITELLM_CPU_CORES" = "0" ]; then
    LITELLM_CPU_CORES="N/A"
fi

# Convert Memory from MiB to GB (divide by 1024)
LITELLM_MEM_GB=$(echo "scale=2; $LITELLM_MEM_MI / 1024" | bc)
if [ -z "$LITELLM_MEM_GB" ] || [ "$LITELLM_MEM_GB" = "0" ]; then
    LITELLM_MEM_GB="N/A"
fi

# KServe model resource usage
KSERVE_CPU_M=$(kubectl top pods -n kserve --no-headers 2>/dev/null | grep predictor | awk '{sum+=$2} END {print sum}' | sed 's/m//' || echo "0")
KSERVE_MEM_MI=$(kubectl top pods -n kserve --no-headers 2>/dev/null | grep predictor | awk '{sum+=$3} END {print sum}' | sed 's/Mi//' || echo "0")
KSERVE_REPLICAS=$(kubectl get pods -n kserve --no-headers 2>/dev/null | grep predictor | grep Running | wc -l)

# Convert CPU millicores to cores
# For small values (< 100m), show as millicores for better visibility
if [ "$KSERVE_CPU_M" -gt 0 ] && [ "$KSERVE_CPU_M" -lt 100 ]; then
    KSERVE_CPU_CORES="${KSERVE_CPU_M}m"
elif [ "$KSERVE_CPU_M" -ge 100 ]; then
    KSERVE_CPU_CORES=$(echo "scale=2; $KSERVE_CPU_M / 1000" | bc)
    KSERVE_CPU_CORES="${KSERVE_CPU_CORES} cores"
else
    KSERVE_CPU_CORES="N/A"
fi

# Convert Memory from MiB to GB
KSERVE_MEM_GB=$(echo "scale=2; $KSERVE_MEM_MI / 1024" | bc)
if [ -z "$KSERVE_MEM_GB" ] || [ "$KSERVE_MEM_GB" = "0" ]; then
    KSERVE_MEM_GB="N/A"
fi

# HPA status
HPA_MIN=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "N/A")
HPA_MAX=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "N/A")
HPA_CURRENT=$(kubectl get hpa litellm-hpa -n litellm -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "N/A")

echo ""
echo "========================================="
echo "Load Test Results Summary"
echo "========================================="
printf "\n"
echo ""
printf "╔════════════════════════════════════╦═══════════════════╗\n"
printf "║ %-34s ║ %-17s ║\n" "METRIC" "VALUE"
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "Model" "$MODEL"
printf "║ %-34s ║ %-17s ║\n" "Payload Type" "$PAYLOAD_TYPE"
printf "║ %-34s ║ %-17s ║\n" "Test Duration" "${DURATION}s"
printf "║ %-34s ║ %-17s ║\n" "Concurrency" "$CONCURRENCY"
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "PERFORMANCE METRICS" ""
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "Avg Response Time (TTFT)" "${AVG_TTFT_MS} ms"
printf "║ %-34s ║ %-17s ║\n" "Avg Output Tokens" "$AVG_TOKENS"
printf "║ %-34s ║ %-17s ║\n" "Output Throughput" "${TOKENS_PER_SEC} tok/s"
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "LITELLM PROXY" ""
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "Replicas (Current/Min/Max)" "$LITELLM_REPLICAS / $HPA_MIN / $HPA_MAX"
if [ "$LITELLM_CPU_CORES" = "N/A" ]; then
    printf "║ %-34s ║ %-17s ║\n" "Total CPU Usage" "$LITELLM_CPU_CORES"
else
    printf "║ %-34s ║ %-17s ║\n" "Total CPU Usage" "${LITELLM_CPU_CORES} cores"
fi
if [ "$LITELLM_MEM_GB" = "N/A" ]; then
    printf "║ %-34s ║ %-17s ║\n" "Total Memory Usage" "$LITELLM_MEM_GB"
else
    printf "║ %-34s ║ %-17s ║\n" "Total Memory Usage" "${LITELLM_MEM_GB} GB"
fi
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "MODEL SERVING (KServe)" ""
printf "╠════════════════════════════════════╬═══════════════════╣\n"
printf "║ %-34s ║ %-17s ║\n" "Model Replicas" "$KSERVE_REPLICAS"
printf "║ %-34s ║ %-17s ║\n" "Total CPU Usage" "$KSERVE_CPU_CORES"
if [ "$KSERVE_MEM_GB" = "N/A" ]; then
    printf "║ %-34s ║ %-17s ║\n" "Total Memory Usage" "$KSERVE_MEM_GB"
else
    printf "║ %-34s ║ %-17s ║\n" "Total Memory Usage" "${KSERVE_MEM_GB} GB"
fi
printf "╚════════════════════════════════════╩═══════════════════╝\n"
echo ""
