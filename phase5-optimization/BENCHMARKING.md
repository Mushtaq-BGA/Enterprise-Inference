# LiteLLM Scalability Benchmarking

This directory contains benchmarking tools to test the scalability and performance of the LiteLLM AI stack, following methodologies from OpenVINO Model Server and vLLM projects.

## Available Benchmarks

### 1. **benchmark-scalability.sh** - OpenVINO-Style Benchmark
Replicates the testing methodology from [OpenVINO Model Server scalability demos](https://github.com/openvinotoolkit/model_server/tree/main/demos/continuous_batching/scaling).

Uses vLLM's `benchmark_serving.py` with the ShareGPT dataset.

**Usage:**
```bash
# Default: 6000 prompts at 20 req/s
./benchmark-scalability.sh

# Custom configuration
NUM_PROMPTS=1000 REQUEST_RATE=10 ./benchmark-scalability.sh

# High load test
NUM_PROMPTS=10000 REQUEST_RATE=50 ./benchmark-scalability.sh
```

**Metrics Reported:**
- Successful requests
- Request throughput (req/s)
- Token throughput (tok/s)
- Time to First Token (TTFT): Mean, Median, P99
- Time per Output Token (TPOT): Mean, Median, P99
- Benchmark duration

### 2. **benchmark-concurrency.py** - vLLM-Style Concurrency Test
Async Python benchmark for detailed per-request latency analysis.

**Usage:**
```bash
source venv/bin/activate

# Quick test - 100 requests, 50 concurrent
python3 benchmark-concurrency.py -n 100 -c 50

# High concurrency
python3 benchmark-concurrency.py -n 500 -c 200

# Custom payload sizes
python3 benchmark-concurrency.py -n 200 -c 100 --input-len 256 --output-len 128

# Rate limited
python3 benchmark-concurrency.py -n 100 --request-rate 10
```

**Metrics Reported:**
- Success rate
- Token counts (input/output)
- TTFT: Mean, P50, P90, P99
- End-to-end latency: Mean, P50, P90, P99
- Throughput: req/s, tokens/s
- JSON output for analysis

### 3. **load-test-baseline.sh** - wrk-Based Load Test
Traditional load testing with wrk/hey/ab tools.

**Usage:**
```bash
# Default: 60s, 100 concurrent
LITELLM_PORT=32080 ./load-test-baseline.sh

# Short test
LITELLM_PORT=32080 DURATION=30 CONCURRENCY=50 ./load-test-baseline.sh

# Different payload types
LITELLM_PORT=32080 PAYLOAD_TYPE=medium ./load-test-baseline.sh
```

**Payload Types:**
- `simple` - 5 tokens
- `small` - ~100 tokens
- `medium` - ~400 tokens
- `large` - ~600 tokens
- `rag` - ~1800 tokens

## Setup

### Initial Setup
```bash
cd /home/ubuntu/ai-stack-production/phase5-optimization

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install aiohttp numpy
```

### For OpenVINO-Style Benchmark
The script will automatically:
1. Clone vLLM repository (v0.7.3)
2. Download ShareGPT dataset
3. Install required dependencies

## Benchmark Comparison

| Benchmark | Tool | Dataset | Best For |
|-----------|------|---------|----------|
| benchmark-scalability.sh | vLLM | ShareGPT | Industry-standard comparison |
| benchmark-concurrency.py | Custom Python | Synthetic | Detailed latency analysis |
| load-test-baseline.sh | wrk/hey/ab | Custom | Quick performance checks |

## Example Results

### OpenVINO-Style Benchmark
```
============ Serving Benchmark Result ============
Successful requests:                     6000
Benchmark duration (s):                  300.00
Request throughput (req/s):              20.00
Output token throughput (tok/s):         1200.00
Total Token throughput (tok/s):          2500.00

---------------Time to First Token----------------
Mean TTFT (ms):                          50.00
Median TTFT (ms):                        45.00
P99 TTFT (ms):                           120.00

-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          15.00
Median TPOT (ms):                        14.00
P99 TPOT (ms):                           25.00
```

### vLLM-Style Concurrency Benchmark
```
╔════════════════════════════════════════╦═══════════════════╗
║ METRIC                                 ║             VALUE ║
╠════════════════════════════════════════╬═══════════════════╣
║ Total Requests                         ║               500 ║
║ Successful Requests                    ║               500 ║
║ Success Rate                           ║           100.00% ║
╠════════════════════════════════════════╬═══════════════════╣
║ TTFT Mean                              ║             0.045 ║
║ TTFT P50                               ║             0.042 ║
║ TTFT P90                               ║             0.098 ║
║ TTFT P99                               ║             0.150 ║
╠════════════════════════════════════════╬═══════════════════╣
║ Requests/sec                           ║             45.50 ║
║ Output Tokens/sec                      ║           1200.00 ║
╚════════════════════════════════════════╩═══════════════════╝
```

## Benchmark Scenarios

### 1. Baseline Performance
```bash
# Measure baseline with moderate load
NUM_PROMPTS=1000 REQUEST_RATE=10 ./benchmark-scalability.sh
```

### 2. Peak Throughput
```bash
# Find maximum sustainable throughput
NUM_PROMPTS=2000 REQUEST_RATE=50 ./benchmark-scalability.sh
```

### 3. Autoscaling Behavior
```bash
# Test HPA scaling with ramp-up
for rate in 5 10 20 30 40; do
    echo "Testing at $rate req/s"
    NUM_PROMPTS=500 REQUEST_RATE=$rate ./benchmark-scalability.sh
    sleep 60  # Wait for scale-down
done
```

### 4. Latency Analysis
```bash
# Detailed latency percentiles
python3 benchmark-concurrency.py -n 1000 -c 100 --input-len 128 --output-len 128
```

## Interpreting Results

### Key Metrics

**TTFT (Time to First Token)**
- Measures time until first token is generated
- Lower is better (< 100ms is excellent for chat)
- P99 should be < 3x median for good UX

**TPOT (Time per Output Token)**
- Time to generate each subsequent token
- Lower is better (< 20ms is excellent)
- Directly affects perceived speed

**Throughput**
- Requests/sec: Total requests processed
- Tokens/sec: Total tokens generated
- Higher is better, but watch latency trade-offs

### Performance Targets

| Metric | Good | Excellent |
|--------|------|-----------|
| TTFT (mean) | < 200ms | < 50ms |
| TPOT (mean) | < 30ms | < 15ms |
| Success rate | > 99% | 100% |
| P99 TTFT | < 500ms | < 150ms |

## Troubleshooting

### High TTFT
- Check model loading time
- Verify CPU/GPU utilization
- Check queue wait times

### High TPOT
- Model may be compute-bound
- Check resource limits
- Consider lower precision (int4 vs fp16)

### Low Throughput
- Increase concurrency
- Check network bottlenecks
- Verify autoscaling is working

### Timeouts
- Increase timeout values
- Check pod readiness
- Verify resource availability

## Advanced Usage

### Custom Dataset
```bash
# Use your own dataset (JSON format)
cd vllm/benchmarks
python benchmark_serving.py \
    --host litellm.aistack.local \
    --port 32080 \
    --endpoint "/v1/chat/completions" \
    --backend "openai-chat" \
    --model "qwen3-4b-int4-ov" \
    --dataset-path custom_dataset.json \
    --num-prompts 1000
```

### Monitoring During Benchmarks
```bash
# Terminal 1: Run benchmark
./benchmark-scalability.sh

# Terminal 2: Monitor pods
watch -n 1 'kubectl get pods -n litellm && kubectl get hpa -n litellm'

# Terminal 3: Monitor resources
watch -n 1 'kubectl top pods -n litellm && kubectl top pods -n kserve'
```

## References

- [OpenVINO Model Server Scaling Demo](https://github.com/openvinotoolkit/model_server/tree/main/demos/continuous_batching/scaling)
- [vLLM Benchmarks](https://github.com/vllm-project/vllm/tree/main/benchmarks)
- [ShareGPT Dataset](https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered)
