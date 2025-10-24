import asyncio
import time
import statistics
import json
import argparse
import random
from pathlib import Path
from openai import AsyncOpenAI

# ---------------- CONFIG ----------------
MODEL = "qwen3-4b-int4-ov"  # Model name registered in LiteLLM proxy
LITELLM_API_BASE = "http://litellm.aistack.local:32080"  # LiteLLM proxy endpoint
API_KEY = "sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef"  # LiteLLM master key
CONCURRENCY = 50
REQUESTS = 200  # total number of prompts
PROMPT = "Explain quantum computing in one sentence."
SHAREGPT_PATH = "test-data/ShareGPT_V3_unfiltered_cleaned_split.json"
INPUT_TOKENS = 256  # Default target input tokens
OUTPUT_TOKENS = 512  # Default max output tokens
# ----------------------------------------

def load_sharegpt_dataset(dataset_path, input_tokens=None, output_tokens=None):
    """Load ShareGPT dataset and filter by token sizes if specified."""
    try:
        with open(dataset_path, 'r') as f:
            dataset = json.load(f)
        
        # Each entry has 'conversations' list with 'from' and 'value' fields
        # We'll use conversations where human asks and gpt responds
        prompts = []
        for entry in dataset:
            if 'conversations' in entry:
                convs = entry['conversations']
                # Find human prompts
                for i, conv in enumerate(convs):
                    if conv.get('from') == 'human' and i + 1 < len(convs):
                        if convs[i + 1].get('from') == 'gpt':
                            human_msg = conv.get('value', '')
                            gpt_msg = convs[i + 1].get('value', '')
                            
                            # Simple token estimation: ~4 chars per token
                            est_input_tokens = len(human_msg) // 4
                            est_output_tokens = len(gpt_msg) // 4
                            
                            # Filter by token sizes if specified
                            if input_tokens and abs(est_input_tokens - input_tokens) > input_tokens * 0.3:
                                continue
                            if output_tokens and abs(est_output_tokens - output_tokens) > output_tokens * 0.3:
                                continue
                            
                            prompts.append(human_msg)
        
        return prompts if prompts else None
    except Exception as e:
        print(f"Error loading ShareGPT dataset: {e}")
        return None


ttft_list = []
tpot_list = []
input_tokens_list = []
output_tokens_list = []
failed_requests = []
retry_count = 0

# Create OpenAI client pointing to LiteLLM proxy
client = AsyncOpenAI(
    base_url=LITELLM_API_BASE, 
    api_key=API_KEY,
    timeout=120.0,  # 2 minute timeout
    max_retries=0   # We'll handle retries manually for better control
)

async def run_request(session_id: int, prompt: str, max_tokens: int = None, max_retries: int = 3):
    global retry_count
    start_time = time.time()
    first_token_time = None
    final_usage = None
    last_error = None

    for attempt in range(max_retries):
        try:
            if attempt > 0:
                retry_count += 1
                # Exponential backoff: 1s, 2s, 4s
                await asyncio.sleep(2 ** (attempt - 1))
                if session_id % 10 == 0:
                    print(f"  Request {session_id}: Retry {attempt}/{max_retries-1}")
            
            params = {
                "model": MODEL,
                "messages": [
                    {"role": "system", "content": "You are a helpful assistant. Answer directly without showing your thinking process."},
                    {"role": "user", "content": prompt}
                ],
                "stream": True,
                "stream_options": {"include_usage": True},
                "extra_body": {
                    "chat_template_kwargs": {"enable_thinking": False}
                }
            }
            if max_tokens:
                params["max_tokens"] = max_tokens
            
            # Reset timing for retry attempts
            start_time = time.time()
            first_token_time = None
            final_usage = None
            chunk_count = 0
                
            stream = await client.chat.completions.create(**params)
            
            async for chunk in stream:
                chunk_count += 1
                if first_token_time is None:
                    first_token_time = time.time()
                
                # Capture final usage info
                if hasattr(chunk, 'usage') and chunk.usage:
                    final_usage = {
                        "prompt_tokens": chunk.usage.prompt_tokens,
                        "completion_tokens": chunk.usage.completion_tokens
                    }

            end_time = time.time()

            # Validate response
            if first_token_time is None:
                raise ValueError("No chunks received from stream")
            
            if final_usage is None:
                raise ValueError("No usage information received")
            
            if final_usage.get("completion_tokens", 0) == 0:
                raise ValueError("Zero completion tokens generated")

            # Calculate metrics
            ttft = first_token_time - start_time
            total_time = end_time - first_token_time
            output_tokens = final_usage.get("completion_tokens", 0)
            tpot = total_time / max(output_tokens, 1)

            # Sanity checks
            if ttft < 0 or ttft > 60:  # TTFT should be between 0-60s
                raise ValueError(f"Invalid TTFT: {ttft:.2f}s")
            
            if tpot < 0 or tpot > 10:  # TPOT should be between 0-10s
                raise ValueError(f"Invalid TPOT: {tpot:.2f}s")

            ttft_list.append(ttft)
            tpot_list.append(tpot)
            input_tokens_list.append(final_usage.get("prompt_tokens", 0))
            output_tokens_list.append(output_tokens)
            
            if session_id % 10 == 0:
                print(f"Request {session_id}: TTFT={ttft*1000:.2f}ms, Tokens={output_tokens}, Chunks={chunk_count}")
            
            return  # Success, exit retry loop
            
        except asyncio.TimeoutError as e:
            last_error = f"Timeout after {time.time() - start_time:.1f}s"
        except Exception as e:
            last_error = str(e)
        
        # If this was the last attempt, log the failure
        if attempt == max_retries - 1:
            failed_requests.append({
                "session_id": session_id,
                "error": last_error,
                "attempts": max_retries
            })
            if len(failed_requests) <= 5:  # Only print first 5 failures
                print(f"Request {session_id} failed after {max_retries} attempts: {last_error}")

async def main():
    global MODEL, LITELLM_API_BASE, API_KEY
    
    parser = argparse.ArgumentParser(description='LiteLLM Benchmark with ShareGPT dataset support')
    parser.add_argument('--model', '-m', type=str, default=MODEL, help='Model name')
    parser.add_argument('--api-base', type=str, default=LITELLM_API_BASE, help='API base URL')
    parser.add_argument('--api-key', type=str, default=API_KEY, help='API key')
    parser.add_argument('--concurrency', '-c', type=int, default=CONCURRENCY, help=f'Concurrent requests (default: {CONCURRENCY})')
    parser.add_argument('--requests', '-n', type=int, default=REQUESTS, help=f'Total requests (default: {REQUESTS})')
    parser.add_argument('--prompt', '-p', type=str, help='Single prompt to use (overrides dataset)')
    parser.add_argument('--dataset', '-d', type=str, default=SHAREGPT_PATH, help=f'Path to ShareGPT dataset (default: {SHAREGPT_PATH})')
    parser.add_argument('--input-tokens', type=int, default=INPUT_TOKENS, help=f'Target input tokens (default: {INPUT_TOKENS})')
    parser.add_argument('--output-tokens', type=int, default=OUTPUT_TOKENS, help=f'Target output tokens (default: {OUTPUT_TOKENS})')
    parser.add_argument('--max-retries', type=int, default=3, help='Max retries per request (default: 3)')
    parser.add_argument('--timeout', type=int, default=120, help='Request timeout in seconds (default: 120)')
    
    args = parser.parse_args()
    
    # Update client timeout
    global client
    client = AsyncOpenAI(
        base_url=args.api_base, 
        api_key=args.api_key,
        timeout=args.timeout,
        max_retries=0
    )
    
    # Update global config
    MODEL = args.model
    LITELLM_API_BASE = args.api_base
    API_KEY = args.api_key
    
    # Determine prompts to use
    prompts = []
    max_tokens = args.output_tokens
    
    if args.prompt:
        # Use single prompt
        prompts = [args.prompt] * args.requests
        print(f"Using single prompt: {args.prompt[:50]}...")
    elif args.dataset and Path(args.dataset).exists():
        # Load ShareGPT dataset
        print(f"Loading ShareGPT dataset from {args.dataset}...")
        dataset_prompts = load_sharegpt_dataset(
            args.dataset, 
            input_tokens=args.input_tokens,
            output_tokens=args.output_tokens
        )
        if dataset_prompts:
            print(f"Loaded {len(dataset_prompts)} prompts from dataset")
            # Sample or repeat to match requested count
            if len(dataset_prompts) >= args.requests:
                prompts = random.sample(dataset_prompts, args.requests)
            else:
                prompts = random.choices(dataset_prompts, k=args.requests)
        else:
            print("Failed to load dataset, using default prompt")
            prompts = [PROMPT] * args.requests
    else:
        # Use default prompt
        prompts = [PROMPT] * args.requests
        print(f"Using default prompt: {PROMPT[:50]}...")
    
    print()
    print("=" * 60)
    print("LiteLLM Benchmark - TTFT & TPOT Measurement")
    print("=" * 60)
    print(f"Model:              {args.model}")
    print(f"API Base:           {args.api_base}")
    print(f"Concurrency:        {args.concurrency}")
    print(f"Requests:           {args.requests}")
    print(f"Input Tokens:       {args.input_tokens or 'variable'}")
    print(f"Max Output Tokens:  {max_tokens or 'unlimited'}")
    print(f"Max Retries:        {args.max_retries}")
    print(f"Timeout:            {args.timeout}s")
    print(f"Dataset:            {args.dataset or 'single prompt'}")
    print("=" * 60)
    print()
    
    # Validate configuration
    if args.concurrency > args.requests:
        print(f"Warning: Concurrency ({args.concurrency}) > Requests ({args.requests})")
        print(f"         Setting concurrency to {args.requests}")
        args.concurrency = args.requests
    
    print(f"Starting benchmark at {time.strftime('%Y-%m-%d %H:%M:%S')}...")
    print()
    
    start_benchmark = time.time()

    tasks = []
    sem = asyncio.Semaphore(args.concurrency)

    async def sem_task(i):
        async with sem:
            await run_request(i, prompts[i], max_tokens, args.max_retries)

    for i in range(args.requests):
        tasks.append(asyncio.create_task(sem_task(i)))

    await asyncio.gather(*tasks)

    end_benchmark = time.time()
    duration = end_benchmark - start_benchmark

    # Compute stats
    successful = len(ttft_list)
    failed = len(failed_requests)
    total_input_tokens = sum(input_tokens_list)
    total_output_tokens = sum(output_tokens_list)
    
    if not ttft_list:
        print("\n❌ No successful requests! Check your configuration and try again.")
        return
    
    median_ttft = statistics.median(ttft_list)
    median_tpot = statistics.median(tpot_list)
    mean_ttft = statistics.mean(ttft_list)
    mean_tpot = statistics.mean(tpot_list)
    
    # Calculate percentiles for better insights
    ttft_sorted = sorted(ttft_list)
    tpot_sorted = sorted(tpot_list)
    p50_idx = len(ttft_sorted) // 2
    p90_idx = int(len(ttft_sorted) * 0.9)
    p99_idx = int(len(ttft_sorted) * 0.99)
    
    p90_ttft = ttft_sorted[p90_idx] if p90_idx < len(ttft_sorted) else ttft_sorted[-1]
    p99_ttft = ttft_sorted[p99_idx] if p99_idx < len(ttft_sorted) else ttft_sorted[-1]
    p90_tpot = tpot_sorted[p90_idx] if p90_idx < len(tpot_sorted) else tpot_sorted[-1]
    p99_tpot = tpot_sorted[p99_idx] if p99_idx < len(tpot_sorted) else tpot_sorted[-1]

    req_throughput = successful / duration
    out_token_throughput = total_output_tokens / duration
    total_throughput = (total_input_tokens + total_output_tokens) / duration
    success_rate = (successful / args.requests) * 100

    print("\n" + "=" * 60)
    print("BENCHMARK RESULTS")
    print("=" * 60)
    print(f"Successful requests:                {successful}/{args.requests} ({success_rate:.1f}%)")
    print(f"Failed requests:                    {failed}")
    if retry_count > 0:
        print(f"Total retries:                      {retry_count}")
    print(f"Benchmark duration (s):             {duration:.2f}")
    print(f"Total input tokens:                 {total_input_tokens}")
    print(f"Total generated tokens:             {total_output_tokens}")
    print(f"Avg tokens per request:             {total_output_tokens/successful:.1f}")
    print()
    print("--- Time to First Token (TTFT) ---")
    print(f"Median TTFT (s):                    {median_ttft:.4f}")
    print(f"Mean TTFT (s):                      {mean_ttft:.4f}")
    print(f"P90 TTFT (s):                       {p90_ttft:.4f}")
    print(f"P99 TTFT (s):                       {p99_ttft:.4f}")
    print(f"Median TTFT (ms):                   {median_ttft*1000:.2f}")
    print(f"Mean TTFT (ms):                     {mean_ttft*1000:.2f}")
    print(f"P90 TTFT (ms):                      {p90_ttft*1000:.2f}")
    print(f"P99 TTFT (ms):                      {p99_ttft*1000:.2f}")
    print()
    print("--- Time per Output Token (TPOT) ---")
    print(f"Median TPOT (s/token):              {median_tpot:.6f}")
    print(f"Mean TPOT (s/token):                {mean_tpot:.6f}")
    print(f"P90 TPOT (s/token):                 {p90_tpot:.6f}")
    print(f"P99 TPOT (s/token):                 {p99_tpot:.6f}")
    print(f"Median TPOT (ms/token):             {median_tpot*1000:.2f}")
    print(f"Mean TPOT (ms/token):               {mean_tpot*1000:.2f}")
    print(f"P90 TPOT (ms/token):                {p90_tpot*1000:.2f}")
    print(f"P99 TPOT (ms/token):                {p99_tpot*1000:.2f}")
    print()
    print("--- Throughput ---")
    print(f"Request throughput (req/s):         {req_throughput:.2f}")
    print(f"Output token throughput (tok/s):    {out_token_throughput:.2f}")
    print(f"Total token throughput (tok/s):     {total_throughput:.2f}")
    print("=" * 60)
    
    # Print failed requests summary if any
    if failed_requests:
        print(f"\n⚠️  Failed Requests Summary ({len(failed_requests)} total):")
        error_counts = {}
        for req in failed_requests:
            error_type = req['error'].split(':')[0] if ':' in req['error'] else req['error']
            error_counts[error_type] = error_counts.get(error_type, 0) + 1
        
        for error, count in sorted(error_counts.items(), key=lambda x: x[1], reverse=True):
            print(f"  {error}: {count} request(s)")
    
    print(f"\nCompleted at {time.strftime('%Y-%m-%d %H:%M:%S')}")

if __name__ == "__main__":
    asyncio.run(main())
