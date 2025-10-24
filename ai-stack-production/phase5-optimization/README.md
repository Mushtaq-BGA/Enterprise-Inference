# Phase 5: High Concurrency Tuning

This phase contains optimizations for handling 1000+ concurrent requests.

## Components Optimized

### 1. LiteLLM Concurrency
- **Workers**: 4 per pod
- **Max Parallel Requests**: 1000 per pod
- **Max Queue Size**: 10000
- **Connection Pool**: 100 database connections
- **HPA**: 3-20 replicas based on CPU (70%) and Memory (80%)

### 2. KServe Autoscaling
- **Min Replicas**: 0 (scale-to-zero for cost savings)
- **Max Replicas**: 10 per model
- **Target Concurrency**: 100 requests/pod
- **Scale Down Delay**: 5 minutes
- **Scale Up**: Aggressive (50% increase or +2 pods every 60s)
- **Scale Down**: Conservative (10% decrease or -1 pod every 60s)

### 3. Redis Optimization
- **Max Memory**: 2GB with LRU eviction
- **Max Clients**: 10000
- **TCP Backlog**: 511
- **Connection Keepalive**: 300s
- **Persistence**: AOF + RDB for durability

### 4. Istio Proxy Tuning
- **Max Connections**: 1000 per service
- **HTTP1 Max Pending**: 1000
- **HTTP2 Max Requests**: 1000
- **Max Requests Per Connection**: 100
- **Circuit Breaking**: 5 consecutive errors, 60s ejection

## Applying Optimizations

All optimizations are already included in Phase 1-4 manifests with production-ready defaults.

### Additional Tuning (Optional)

1. **Increase LiteLLM replicas** (if you have more resources):
   ```bash
   kubectl scale deployment litellm -n litellm --replicas=10
   kubectl patch hpa litellm-hpa -n litellm --patch '{"spec":{"maxReplicas":50}}'
   ```

2. **Increase KServe model replicas**:
   ```bash
   kubectl patch inferenceservice <model-name> -n kserve --type=merge \
     -p '{"spec":{"predictor":{"minReplicas":2,"maxReplicas":20}}}'
   ```

3. **Tune Istio proxy resources**:
   ```bash
   kubectl patch deployment litellm -n litellm --type=json \
     -p='[{"op":"add","path":"/spec/template/metadata/annotations/sidecar.istio.io~1proxyCPU","value":"1000m"}]'
   ```

## Load Testing

Phase 5 includes comprehensive load testing scripts with beautiful metrics tables showing TTFT, throughput, CPU, and memory consumption.

### Prerequisites

Install a load testing tool (wrk is recommended):

```bash
# Option 1: wrk (recommended - available via apt)
sudo apt-get install wrk

# Option 2: hey (requires Go)
go install github.com/rakyll/hey@latest

# Option 3: Apache Bench
sudo apt-get install apache2-utils
```

### Prepare Test Data (Optional but Recommended)

The load tests can use realistic conversation data from the ShareGPT dataset:

```bash
cd phase5-optimization
./prepare-test-data.sh
```

This will:
- Download the ShareGPT dataset (~642MB, 94,145 conversations)
- Categorize conversations by token length
- Create 100 samples for each payload category
- Store in `test-data/payloads_{small,medium,large,rag}.json`

**Available Payload Types:**

Each type specifies **INPUT tokens** (prompt size) → **OUTPUT tokens** (max_tokens setting):

- **simple**: ~5 input → 30 output (~35 total) - micro-benchmark only
- **small**: 50-150 input → 100 output (~150-250 total) - quick Q&A
- **medium**: 150-500 input → 200 output (~350-700 total) - code explanations  
- **large**: 500-1500 input → 300 output (~800-1800 total) - complex analysis
- **rag**: 1500+ input → 400 output (1900+ total) - document Q&A with context

**Actual ShareGPT Dataset Averages** (from prepared test data):
- small: ~73 input tokens → 100 output
- medium: ~163 input tokens → 200 output
- large: ~1,078 input tokens → 300 output
- rag: ~1,544 input tokens → 400 output

**Realistic Performance Expectations** (10 concurrent, single model instance):

| Payload | Input→Output Tokens | TTFT | Throughput | Requests/sec | Use Case |
|---------|---------------------|------|------------|--------------|----------|
| simple | 5→30 | 12ms | ~2,500 tok/s | ~5,000 | Micro-benchmark |
| small | 73→100 | 13ms | ~7,650 tok/s | ~1,200 | Quick answers |
| medium | 163→200 | 12ms | ~15,500 tok/s | ~780 | Code help |
| large | 1,078→300 | 4,000ms | ~75 tok/s | ~10 | Deep analysis |
| rag | 1,544→400 | TBD | TBD | TBD | Context-aware |

⚠️ **Important Notes**:
- **Input tokens** = prompt size (what you send to the model)
- **Output tokens** = generated response length (max_tokens parameter)
- **TTFT** (Time To First Token) = latency before streaming starts
- Large prompts (>500 tokens) cause high TTFT due to prompt processing - this is expected real-world behavior
- Throughput measured in tokens/second during generation phase only

### Test Scripts

#### 1. Baseline Performance Test

Tests sustained load with configurable duration and concurrency.

**Usage:**
```bash
cd phase5-optimization

# Quick test with realistic medium payload (20s, 10 concurrent)
LITELLM_PORT=32080 PAYLOAD_TYPE=medium DURATION=20 CONCURRENCY=10 \
  ./load-test-baseline.sh

# Test different payload sizes
LITELLM_PORT=32080 PAYLOAD_TYPE=small DURATION=30 CONCURRENCY=20 \
  ./load-test-baseline.sh

LITELLM_PORT=32080 PAYLOAD_TYPE=large DURATION=30 CONCURRENCY=5 \
  ./load-test-baseline.sh

# Standard stress test (60s, 100 concurrent)
LITELLM_PORT=32080 PAYLOAD_TYPE=medium DURATION=60 CONCURRENCY=100 \
  ./load-test-baseline.sh
```

**Environment Variables:**
- `LITELLM_PORT`: Istio ingress gateway port (default: 30080)
- `PAYLOAD_TYPE`: Payload size - simple|small|medium|large|rag (default: simple)
- `DURATION`: Test duration in seconds (default: 60)
- `CONCURRENCY`: Number of concurrent connections (default: 100)
- `SAMPLE_REQUESTS`: Number of requests to sample for TTFT (default: 10)
- `MODEL`: Model name to test (default: qwen3-4b-int4-ov)

**Output Example:**
```
╔════════════════════════════════════╦═══════════════════╗
║ METRIC                             ║ VALUE             ║
╠════════════════════════════════════╬═══════════════════╣
║ Model                              ║ qwen3-4b-int4-ov  ║
║ Payload Type                       ║ medium            ║
║ Test Duration                      ║ 30s               ║
║ Concurrency                        ║ 10                ║
╠════════════════════════════════════╬═══════════════════╣
║ PERFORMANCE METRICS                ║                   ║
╠════════════════════════════════════╬═══════════════════╣
║ Avg Response Time (TTFT)           ║ 12.000 ms         ║
║ Avg Output Tokens                  ║ 200.0             ║
║ Output Throughput                  ║ 15506.24 tok/s    ║
╠════════════════════════════════════╬═══════════════════╣
║ LITELLM PROXY                      ║                   ║
╠════════════════════════════════════╬═══════════════════╣
║ Replicas (Current/Min/Max)         ║ 20 / 3 / 20       ║
║ Total CPU Usage                    ║ 3.30 cores        ║
║ Total Memory Usage                 ║ 62.65 GB          ║
╠════════════════════════════════════╬═══════════════════╣
║ MODEL SERVING (KServe)             ║                   ║
╠════════════════════════════════════╬═══════════════════╣
║ Model Replicas                     ║ 2                 ║
║ Total CPU Usage                    ║ 8.42 cores        ║
║ Total Memory Usage                 ║ 4.08 GB           ║
╚════════════════════════════════════╩═══════════════════╝
```

**Metrics Explained:**
- **TTFT** (Time To First Token): Latency before response streaming begins (includes prompt processing)
- **Avg Output Tokens**: Average number of tokens generated per response (completion tokens)
- **Output Throughput**: Generated tokens per second (completion_tokens / total_time, includes TTFT overhead)
- Output throughput is measured across the full request lifecycle, so large TTFT reduces overall tok/s

#### 2. Ramp-up Concurrency Test

Gradually increases load to test autoscaling behavior. Tests with multiple payload types recommended.

**Standard Test (Default - up to 500 concurrent):**
```bash
cd phase5-optimization

# Test autoscaling with medium payload (recommended)
LITELLM_PORT=32080 PAYLOAD_TYPE=medium ./load-test-rampup.sh

# Test with small payload for faster execution
LITELLM_PORT=32080 PAYLOAD_TYPE=small ./load-test-rampup.sh
```

**Extended Test (Up to 1000 concurrent):**
```bash
# Run extended test (adds 750 and 1000 concurrent levels)
LITELLM_PORT=32080 PAYLOAD_TYPE=medium EXTENDED_TEST=true ./load-test-rampup.sh
cd phase5-optimization

# Standard ramp-up: 100 → 250 → 500 concurrent users
LITELLM_PORT=32080 ./load-test-rampup.sh
```

**Extended Test (up to 1000 concurrent):**
```bash
cd phase5-optimization

# Extended ramp-up: 100 → 250 → 500 → 750 → 1000 concurrent users
LITELLM_PORT=32080 EXTENDED_TEST=true ./load-test-rampup.sh
```

**Test Levels:**
- **100 users**: 60 seconds (baseline autoscaling)
- **250 users**: 60 seconds (moderate load)
- **500 users**: 90 seconds (high load)
- **750 users**: 90 seconds (extended only - stress test)
- **1000 users**: 120 seconds (extended only - maximum capacity)

**Output Example:**
After each test level:
```
╔════════════════════╦═══════════╦════════════╦═══════════╗
║ Component          ║ Replicas  ║ CPU        ║ Memory    ║
╠════════════════════╬═══════════╬════════════╬═══════════╣
║ LiteLLM Proxy      ║ 14        ║ 37.63 cores ║ 30.10 GB ║
║ KServe Model       ║ 1         ║ 3m         ║ 3.39 GB   ║
╚════════════════════╩═══════════╩════════════╩═══════════╝
```

Final Summary:
```
╔════════════════════════════════════╦═══════════════════╗
║ METRIC                             ║ VALUE             ║
╠════════════════════════════════════╬═══════════════════╣
║ Test Type                          ║ Ramp-up           ║
║ Model                              ║ qwen3-4b-int4-ov  ║
║ Concurrency Tested                 ║ 100→500          ║
╠════════════════════════════════════╬═══════════════════╣
║ LITELLM PROXY (Final State)        ║                   ║
╠════════════════════════════════════╬═══════════════════╣
║ Replicas (Current/Min/Max)         ║ 14 / 3 / 20       ║
║ Current CPU Utilization            ║ 65%               ║
║ Total CPU Usage                    ║ 32.45 cores       ║
║ Total Memory Usage                 ║ 28.50 GB          ║
╚════════════════════════════════════╩═══════════════════╝
```

### Understanding Metrics

**Performance Metrics:**
- **TTFT (Time To First Token)**: Response time in milliseconds
- **Completion Tokens**: Average tokens generated per request
- **Generation Speed**: Tokens per second throughput

**Resource Metrics:**
- **CPU Usage**: 
  - `X cores` for high usage (≥ 100m)
  - `Xm` for low/idle usage (< 100m)
- **Memory Usage**: Total memory consumption in GB
- **Replicas**: Current/Min/Max for HPA-managed deployments

### Expected Performance

With default configuration on a 4-core/16GB node:

| Metric | Target | Actual (Typical) |
|--------|--------|------------------|
| Max Concurrent Requests | 500 | 400-600 |
| TTFT (Avg) | <50ms | 10-30ms |
| Latency (p50) | <100ms | 50-80ms |
| Latency (p95) | <500ms | 200-400ms |
| Latency (p99) | <1000ms | 500-800ms |
| Throughput | >2000 req/s | 1800-3500 req/s |
| Tokens/sec | >3000 tok/s | 3000-4000 tok/s |
| Error Rate | <1% | 0.1-0.5% |

**Note:** Extended test (1000 concurrent) may hit HPA limits (20 replicas max) and show higher latency.

### Tips for Load Testing

1. **Start Small**: Begin with baseline test at low concurrency (10-20)
2. **Monitor Resources**: Watch `kubectl top nodes` and `kubectl top pods`
3. **Standard First**: Run standard ramp-up test before extended
4. **Cool Down**: Allow 2-3 minutes between tests for pods to stabilize
5. **Adjust HPA**: Increase maxReplicas if consistently hitting limits:
   ```bash
   kubectl patch hpa litellm-hpa -n litellm --patch '{"spec":{"maxReplicas":30}}'
   ```

### Troubleshooting Load Tests

**Script shows "No load testing tools found":**
```bash
# Install wrk (easiest option)
sudo apt-get update && sudo apt-get install -y wrk
```

**High error rates during testing:**
- Check if HPA has scaled up: `kubectl get hpa -n litellm`
- Increase HPA max replicas
- Reduce concurrency level
- Check pod logs: `kubectl logs -n litellm -l app=litellm --tail=100`

**Timeouts during extended test:**
- Normal behavior under extreme load (750-1000 concurrent)
- Indicates system is at capacity
- Consider adding more nodes or reducing concurrency

## Monitoring

### Key Metrics to Watch

1. **LiteLLM**:
   - Request rate and latency
   - Queue size and wait time
   - HPA scaling events
   - Database connection pool utilization

2. **KServe**:
   - Model replica count
   - Request concurrency per pod
   - Scale-to-zero events
   - Cold start latency

3. **Redis**:
   - Cache hit rate
   - Memory usage
   - Client connections
   - Command latency

4. **Istio**:
   - Circuit breaker trips
   - Connection pool exhaustion
   - Retry attempts
   - Timeout errors

### Prometheus Queries

```promql
# LiteLLM request rate
rate(http_requests_total{namespace="litellm"}[5m])

# KServe model concurrency
kserve_model_concurrency{namespace="kserve"}

# Redis cache hit rate
redis_cache_hits_total / (redis_cache_hits_total + redis_cache_misses_total)

# Istio request duration p95
histogram_quantile(0.95, rate(istio_request_duration_milliseconds_bucket[5m]))
```

## Troubleshooting

### High Latency

1. Check LiteLLM queue size:
   ```bash
   kubectl logs -n litellm deployment/litellm | grep "queue"
   ```

2. Check if models are scaled up:
   ```bash
   kubectl get pods -n kserve
   ```

3. Check Istio circuit breakers:
   ```bash
   istioctl proxy-config clusters deployment/litellm.litellm
   ```

### Request Timeouts

1. Increase timeout in VirtualService:
   ```bash
   kubectl patch virtualservice litellm-vs -n litellm --type=merge \
     -p '{"spec":{"http":[{"timeout":"900s"}]}}'
   ```

2. Increase request timeout in LiteLLM:
   ```bash
   kubectl patch configmap litellm-config -n litellm --type=merge \
     -p '{"data":{"config.yaml":"request_timeout: 900"}}'
   ```

### Memory Issues

1. Increase LiteLLM memory limits:
   ```bash
   kubectl patch deployment litellm -n litellm --type=json \
     -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"16Gi"}]'
   ```

2. Increase Redis max memory:
   ```bash
   kubectl patch configmap redis-config -n redis --type=merge \
     -p '{"data":{"redis.conf":"maxmemory 4gb"}}'
   ```

## Best Practices

1. **Always load test gradually**: Start with 100 concurrent users, then 500, then 1000
2. **Monitor resource usage**: Use `kubectl top nodes` and `kubectl top pods`
3. **Set resource requests = limits**: For predictable performance
4. **Enable PodDisruptionBudgets**: Maintain availability during updates
5. **Use connection pooling**: Reduces overhead and improves throughput
6. **Implement rate limiting**: Protect backend services from overload
7. **Cache aggressively**: Reduces load on model servers
8. **Use async processing**: For non-latency-sensitive requests

## Advanced Optimizations

### 1. Multi-Zone Deployment
For high availability, spread pods across availability zones.

### 2. GPU Acceleration
For compute-intensive models, use GPU nodes:
```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

### 3. Model Quantization
Use INT8/INT4 models for better throughput:
- INT8: 2-3x faster inference
- INT4: 4-5x faster inference
- Minimal accuracy loss (<1%)

### 4. Batching
Enable dynamic batching in model servers for higher throughput.

### 5. Caching
Implement semantic caching for repeated queries.
