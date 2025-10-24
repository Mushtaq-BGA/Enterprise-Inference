# Model Benchmark Load Test

A comprehensive Python script to accurately measure model performance metrics including **Time To First Token (TTFT)**, **latency**, and **token throughput** under concurrent load.

## Features

- ✅ **Accurate TTFT measurement** - Measures time to first token in streaming responses
- ✅ **Detailed latency metrics** - P50, P95, P99 percentiles
- ✅ **Token throughput** - Per-request and overall throughput
- ✅ **Concurrent load testing** - Configurable concurrency levels
- ✅ **Streaming support** - Optimized for SSE/streaming endpoints
- ✅ **Comprehensive statistics** - Success rates, error tracking
- ✅ **JSON export** - Detailed results for analysis

## Installation

```bash
pip install -r benchmark_requirements.txt
```

Or install directly:
```bash
pip install aiohttp
```

## Usage

### Basic Usage

```bash
python3 benchmark_model.py \
  --endpoint http://localhost:8000/v1/chat/completions \
  --model "HuggingFaceTB/SmolLM2-1.7B-Instruct" \
  --requests 100 \
  --concurrency 10
```

### Full Options

```bash
python3 benchmark_model.py \
  --endpoint http://your-endpoint/v1/chat/completions \
  --model "model-name" \
  --api-key "your-api-key" \
  --requests 200 \
  --concurrency 20 \
  --max-tokens 150 \
  --prompt-type varied \
  --output results.json \
  --timeout 300
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--endpoint` | Yes | - | Model endpoint URL (OpenAI-compatible chat/completions) |
| `--model` | Yes | - | Model name to use in requests |
| `--api-key` | No | - | API key for authentication |
| `--requests` | No | 100 | Total number of requests to send |
| `--concurrency` | No | 10 | Number of concurrent requests |
| `--max-tokens` | No | 100 | Maximum tokens to generate per request |
| `--prompt-type` | No | varied | Prompt type: `simple`, `varied`, or `long` |
| `--output` | No | Auto-generated | Output JSON file path |
| `--timeout` | No | 300 | Request timeout in seconds |

## Prompt Types

- **simple**: Single repeated prompt (tests consistent load)
- **varied**: 10 different prompts rotated (realistic mixed workload)
- **long**: Complex multi-sentence prompts (stress test)

## Example Commands

### Test LiteLLM Endpoint
```bash
python3 benchmark_model.py \
  --endpoint http://192.168.1.100/v1/chat/completions \
  --model "HuggingFaceTB/SmolLM2-1.7B-Instruct" \
  --requests 50 \
  --concurrency 5 \
  --max-tokens 100
```

### High Concurrency Test
```bash
python3 benchmark_model.py \
  --endpoint http://localhost:8000/v1/chat/completions \
  --model "meta-llama/Llama-3.2-1B-Instruct" \
  --requests 500 \
  --concurrency 50 \
  --max-tokens 50 \
  --prompt-type simple
```

### Long Context Test
```bash
python3 benchmark_model.py \
  --endpoint http://localhost:8000/v1/chat/completions \
  --model "microsoft/Phi-3-mini-4k-instruct" \
  --requests 100 \
  --concurrency 10 \
  --max-tokens 500 \
  --prompt-type long
```

## Output Metrics

### Summary Statistics
- Total requests (successful/failed)
- Success rate
- Requests per second
- Total duration

### Time To First Token (TTFT)
- Average, P50, P95, P99
- Min/Max values
- Critical for user experience

### Total Latency
- End-to-end request duration
- Average, P50, P95, P99
- Min/Max values

### Throughput
- Tokens per second (per request)
- Overall system throughput
- Total tokens generated

## Sample Output

```
================================================================================
BENCHMARK RESULTS
================================================================================

📊 SUMMARY
  Total Requests:      100
  Successful:          98
  Failed:              2
  Success Rate:        98.00%
  Concurrency:         10
  Total Duration:      45.23s
  Requests/sec:        2.17

⚡ TIME TO FIRST TOKEN (TTFT)
  Average:             245.32 ms
  P50:                 230.15 ms
  P95:                 350.42 ms
  P99:                 425.18 ms
  Min:                 180.23 ms
  Max:                 502.45 ms

⏱️  TOTAL LATENCY
  Average:             4.52s
  P50:                 4.38s
  P95:                 5.12s
  P99:                 5.89s
  Min:                 3.45s
  Max:                 6.23s

🚀 THROUGHPUT
  Avg tokens/sec (per request): 22.15
  Overall throughput:  215.43 tokens/sec
  Total tokens:        9745
  Total prompt tokens: 1250

================================================================================
```

## JSON Output

The benchmark saves detailed results to a JSON file containing:
- Summary statistics
- Individual request metrics
- Timestamps and configuration
- Error details for failed requests

Example structure:
```json
{
  "timestamp": "2025-10-23T10:30:00",
  "endpoint": "http://localhost:8000/v1/chat/completions",
  "model": "model-name",
  "summary": {
    "total_requests": 100,
    "successful_requests": 98,
    "avg_ttft": 0.245,
    ...
  },
  "individual_requests": [
    {
      "request_id": 0,
      "ttft": 0.230,
      "total_latency": 4.52,
      "tokens_generated": 100,
      "tokens_per_second": 22.12,
      "success": true
    },
    ...
  ]
}
```

## Performance Tips

1. **Start Small**: Begin with low concurrency (5-10) and gradually increase
2. **Network Latency**: Run from the same network as your endpoint
3. **Timeout Settings**: Adjust `--timeout` based on expected response times
4. **Resource Monitoring**: Monitor CPU/GPU/memory on the inference server
5. **Warm-up**: Run a small test first to warm up the model

## Troubleshooting

### Connection Errors
- Verify endpoint URL is correct and accessible
- Check if service is running: `curl http://endpoint/health`
- Ensure firewall/network policies allow traffic

### All Requests Fail
- Check API key if required
- Verify model name matches deployed model
- Review endpoint logs for errors

### Timeout Issues
- Increase `--timeout` value
- Reduce `--max-tokens`
- Lower `--concurrency`

### Inconsistent Results
- Use `--prompt-type simple` for consistent load
- Increase `--requests` for more reliable statistics
- Check for background load on inference server

## Integration with AI Stack

### Testing KServe InferenceService
```bash
# Get the external IP
EXTERNAL_IP=$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

python3 benchmark_model.py \
  --endpoint "http://${EXTERNAL_IP}/v1/chat/completions" \
  --model "HuggingFaceTB/SmolLM2-1.7B-Instruct" \
  --requests 100 \
  --concurrency 10
```

### Testing LiteLLM Gateway
```bash
python3 benchmark_model.py \
  --endpoint "http://litellm-gateway-ip/v1/chat/completions" \
  --model "your-model-name" \
  --api-key "$(kubectl get secret litellm-api-key -n litellm -o jsonpath='{.data.key}' | base64 -d)" \
  --requests 200 \
  --concurrency 20
```

## Advanced Analysis

### Compare Different Concurrency Levels
```bash
for CONC in 5 10 20 50; do
  python3 benchmark_model.py \
    --endpoint http://localhost:8000/v1/chat/completions \
    --model "model-name" \
    --requests 100 \
    --concurrency $CONC \
    --output "results_conc_${CONC}.json"
done
```

### Analyze Results
```python
import json
import pandas as pd

# Load results
with open('benchmark_results.json') as f:
    data = json.load(f)

# Convert to DataFrame
df = pd.DataFrame(data['individual_requests'])

# Analyze
print(f"Mean TTFT: {df['ttft'].mean():.3f}s")
print(f"95th percentile latency: {df['total_latency'].quantile(0.95):.3f}s")
print(f"Total throughput: {df['tokens_generated'].sum() / data['summary']['total_duration']:.2f} tokens/sec")
```

## License

Part of the AI Stack Production deployment toolkit.
