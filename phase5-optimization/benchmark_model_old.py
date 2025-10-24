#!/usr/bin/env python3
"""
Model Benchmark Load Test Script
Measures TTFT, latency, and token throughput for concurrent requests
"""

import asyncio
import aiohttp
import ssl
import time
import json
import argparse
import statistics
import os
from datetime import datetime
from typing import List, Dict, Any
from dataclasses import dataclass, asdict
from pathlib import Path
import sys


@dataclass
class RequestMetrics:
    """Metrics for a single request"""
    request_id: int
    ttft: float  # Time to first token (seconds)
    total_latency: float  # Total request duration (seconds)
    tokens_generated: int
    tokens_per_second: float
    prompt_tokens: int
    success: bool
    error: str = None
    start_time: float = 0
    end_time: float = 0


@dataclass
class BenchmarkResults:
    """Aggregated benchmark results"""
    total_requests: int
    successful_requests: int
    failed_requests: int
    concurrency: int
    
    # TTFT metrics
    avg_ttft: float
    p50_ttft: float
    p95_ttft: float
    p99_ttft: float
    min_ttft: float
    max_ttft: float
    
    # Latency metrics
    avg_latency: float
    p50_latency: float
    p95_latency: float
    p99_latency: float
    min_latency: float
    max_latency: float
    
    # Throughput metrics
    avg_tokens_per_second: float
    total_tokens_generated: int
    total_prompt_tokens: int
    overall_throughput: float  # Total tokens / total time
    
    # Duration
    total_duration: float
    requests_per_second: float


class ModelBenchmark:
    """Benchmark tool for model inference endpoints"""
    
    def __init__(self, 
                 endpoint_url: str,
                 model_name: str,
                 api_key: str = None,
                 timeout: int = 300):
        self.endpoint_url = endpoint_url
        self.model_name = model_name
        self.api_key = api_key
        self.timeout = aiohttp.ClientTimeout(total=timeout)
        
    async def send_request(self, 
                          session: aiohttp.ClientSession,
                          prompt: str,
                          request_id: int,
                          max_tokens: int = 100) -> RequestMetrics:
        """Send a single request and measure metrics"""
        
        headers = {
            "Content-Type": "application/json"
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        
        payload = {
            "model": self.model_name,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "stream": True,
            "temperature": 0.7
        }
        
        metrics = RequestMetrics(
            request_id=request_id,
            ttft=0,
            total_latency=0,
            tokens_generated=0,
            tokens_per_second=0,
            prompt_tokens=len(prompt.split()),  # Rough estimate
            success=False
        )
        
        try:
            start_time = time.perf_counter()
            metrics.start_time = start_time
            
            first_token_time = None
            tokens_received = 0
            
            async with session.post(
                self.endpoint_url,
                json=payload,
                headers=headers,
                timeout=self.timeout
            ) as response:
                
                if response.status != 200:
                    error_text = await response.text()
                    metrics.error = f"HTTP {response.status}: {error_text}"
                    metrics.end_time = time.perf_counter()
                    return metrics
                
                # Stream response and measure TTFT
                async for line in response.content:
                    if not line:
                        continue
                    
                    line = line.decode('utf-8').strip()
                    if not line.startswith('data: '):
                        continue
                    
                    data = line[6:]  # Remove 'data: ' prefix
                    if data == '[DONE]':
                        break
                    
                    try:
                        chunk = json.loads(data)
                        if 'choices' in chunk and len(chunk['choices']) > 0:
                            delta = chunk['choices'][0].get('delta', {})
                            if 'content' in delta and delta['content']:
                                if first_token_time is None:
                                    first_token_time = time.perf_counter()
                                    metrics.ttft = first_token_time - start_time
                                tokens_received += 1
                    except json.JSONDecodeError:
                        continue
            
            end_time = time.perf_counter()
            metrics.end_time = end_time
            metrics.total_latency = end_time - start_time
            metrics.tokens_generated = tokens_received
            
            if metrics.total_latency > 0 and tokens_received > 0:
                metrics.tokens_per_second = tokens_received / metrics.total_latency
            
            metrics.success = True
            
        except asyncio.TimeoutError:
            metrics.error = "Request timeout"
            metrics.end_time = time.perf_counter()
        except Exception as e:
            metrics.error = str(e)
            metrics.end_time = time.perf_counter()
        
        return metrics
    
    async def run_concurrent_requests(self,
                                      prompts: List[str],
                                      concurrency: int,
                                      max_tokens: int = 100) -> List[RequestMetrics]:
        """Run multiple requests concurrently"""
        
        connector = aiohttp.TCPConnector(limit=concurrency * 2)
        async with aiohttp.ClientSession(connector=connector) as session:
            tasks = []
            for i, prompt in enumerate(prompts):
                task = self.send_request(session, prompt, i, max_tokens)
                tasks.append(task)
            
            # Run with controlled concurrency
            results = []
            for i in range(0, len(tasks), concurrency):
                batch = tasks[i:i + concurrency]
                batch_results = await asyncio.gather(*batch)
                results.extend(batch_results)
                
                # Small delay between batches to avoid overwhelming the system
                if i + concurrency < len(tasks):
                    await asyncio.sleep(0.1)
            
            return results
    
    def calculate_percentile(self, values: List[float], percentile: float) -> float:
        """Calculate percentile from a list of values"""
        if not values:
            return 0.0
        sorted_values = sorted(values)
        index = int(len(sorted_values) * percentile / 100)
        return sorted_values[min(index, len(sorted_values) - 1)]
    
    def aggregate_results(self, 
                         metrics_list: List[RequestMetrics],
                         total_duration: float) -> BenchmarkResults:
        """Aggregate individual request metrics"""
        
        successful = [m for m in metrics_list if m.success]
        failed = [m for m in metrics_list if not m.success]
        
        if not successful:
            print("ERROR: No successful requests!")
            return None
        
        ttfts = [m.ttft for m in successful if m.ttft > 0]
        latencies = [m.total_latency for m in successful]
        throughputs = [m.tokens_per_second for m in successful if m.tokens_per_second > 0]
        
        total_tokens = sum(m.tokens_generated for m in successful)
        total_prompt_tokens = sum(m.prompt_tokens for m in successful)
        
        results = BenchmarkResults(
            total_requests=len(metrics_list),
            successful_requests=len(successful),
            failed_requests=len(failed),
            concurrency=0,  # Will be set by caller
            
            # TTFT
            avg_ttft=statistics.mean(ttfts) if ttfts else 0,
            p50_ttft=self.calculate_percentile(ttfts, 50) if ttfts else 0,
            p95_ttft=self.calculate_percentile(ttfts, 95) if ttfts else 0,
            p99_ttft=self.calculate_percentile(ttfts, 99) if ttfts else 0,
            min_ttft=min(ttfts) if ttfts else 0,
            max_ttft=max(ttfts) if ttfts else 0,
            
            # Latency
            avg_latency=statistics.mean(latencies),
            p50_latency=self.calculate_percentile(latencies, 50),
            p95_latency=self.calculate_percentile(latencies, 95),
            p99_latency=self.calculate_percentile(latencies, 99),
            min_latency=min(latencies),
            max_latency=max(latencies),
            
            # Throughput
            avg_tokens_per_second=statistics.mean(throughputs) if throughputs else 0,
            total_tokens_generated=total_tokens,
            total_prompt_tokens=total_prompt_tokens,
            overall_throughput=total_tokens / total_duration if total_duration > 0 else 0,
            
            # Duration
            total_duration=total_duration,
            requests_per_second=len(successful) / total_duration if total_duration > 0 else 0
        )
        
        return results
    
    def print_results(self, results: BenchmarkResults, metrics_list: List[RequestMetrics]):
        """Print formatted benchmark results"""
        
        print("\n" + "="*80)
        print("BENCHMARK RESULTS")
        print("="*80)
        
        print(f"\n📊 SUMMARY")
        print(f"  Successful requests:                     {results.successful_requests}")
        print(f"  Failed requests:                         {results.failed_requests}")
        print(f"  Benchmark duration (s):                  {results.total_duration:.2f}")
        print(f"  Total input tokens:                      {results.total_prompt_tokens}")
        print(f"  Total generated tokens:                  {results.total_tokens_generated}")
        print(f"  Request throughput (req/s):              {results.requests_per_second:.2f}")
        print(f"  Output token throughput (tok/s):         {results.overall_throughput:.2f}")
        print(f"  Total Token throughput (tok/s):          {(results.total_tokens_generated + results.total_prompt_tokens) / results.total_duration:.2f}")
        
        print(f"\n⚡ TIME TO FIRST TOKEN (TTFT)")
        print(f"  Average:             {results.avg_ttft*1000:.2f} ms")
        print(f"  P99:                 {results.p99_ttft*1000:.2f} ms")
        
        print(f"\n⏱️  TOTAL LATENCY")
        print(f"  Average:             {results.avg_latency:.2f}s")
        print(f"  P99:                 {results.p99_latency:.2f}s")
        
        print(f"\n🚀 THROUGHPUT")
        print(f"  Avg tokens/sec (per request):            {results.avg_tokens_per_second:.2f}")
        
        # Print failed requests if any
        failed = [m for m in metrics_list if not m.success]
        if failed:
            print(f"\n❌ FAILED REQUESTS ({len(failed)})")
            for m in failed[:10]:  # Show first 10
                print(f"  Request {m.request_id}: {m.error}")
            if len(failed) > 10:
                print(f"  ... and {len(failed) - 10} more")
        
        print("\n" + "="*80)
    
    def save_results(self, 
                    results: BenchmarkResults, 
                    metrics_list: List[RequestMetrics],
                    output_file: str):
        """Save detailed results to JSON file"""
        
        data = {
            "timestamp": datetime.now().isoformat(),
            "endpoint": self.endpoint_url,
            "model": self.model_name,
            "summary": asdict(results),
            "individual_requests": [asdict(m) for m in metrics_list]
        }
        
        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2)
        
        print(f"\n💾 Detailed results saved to: {output_file}")


def load_sharegpt_prompts(dataset_path: str, num_prompts: int, input_size: int = None) -> List[str]:
    """Load prompts from ShareGPT dataset"""
    
    try:
        with open(dataset_path, 'r') as f:
            data = json.load(f)
        
        prompts = []
        for item in data[:num_prompts]:
            # Extract the first human message from conversations
            for conv in item.get('conversations', []):
                if conv.get('from') == 'human':
                    prompt = conv.get('value', '')
                    if prompt:
                        # If input_size is specified, truncate to approximate token count
                        if input_size:
                            # Rough approximation: 1 token ~= 4 characters
                            max_chars = input_size * 4
                            prompt = prompt[:max_chars]
                        prompts.append(prompt)
                        break
            
            if len(prompts) >= num_prompts:
                break
        
        return prompts[:num_prompts]
    
    except Exception as e:
        print(f"Error loading ShareGPT dataset: {e}")
        print("Falling back to default prompts...")
        return generate_default_prompts(num_prompts)


def load_payload_prompts(dataset_path: str, num_prompts: int) -> List[str]:
    """Load prompts from pre-prepared payload files (small, medium, large, rag)"""
    
    try:
        with open(dataset_path, 'r') as f:
            data = json.load(f)
        
        prompts = []
        for item in data[:num_prompts]:
            content = item.get('content', '')
            if content:
                prompts.append(content)
            
            if len(prompts) >= num_prompts:
                break
        
        return prompts[:num_prompts]
    
    except Exception as e:
        print(f"Error loading payload dataset: {e}")
        print("Falling back to default prompts...")
        return generate_default_prompts(num_prompts)


def generate_default_prompts(num_prompts: int) -> List[str]:
    """Generate default test prompts as fallback"""
    
    base_prompts = [
        "Explain the concept of machine learning in simple terms.",
        "Write a short story about a robot learning to paint.",
        "What are the benefits of renewable energy?",
        "Describe the water cycle in detail.",
        "How does photosynthesis work in plants?",
        "Explain quantum computing to a beginner.",
        "What are the main causes of climate change?",
        "Describe the process of protein synthesis.",
        "What is the significance of the Renaissance period?",
        "Explain how neural networks learn from data."
    ]
    prompts = []
    for i in range(num_prompts):
        prompts.append(base_prompts[i % len(base_prompts)])
    return prompts


def generate_test_prompts(num_prompts: int, prompt_type: str = "varied", dataset: str = "sharegpt", input_size: int = None) -> List[str]:
    """Generate test prompts"""
    
    script_dir = Path(__file__).parent
    
    # Map dataset names to file paths
    dataset_files = {
        "sharegpt": "ShareGPT_V3_unfiltered_cleaned_split.json",
        "small": "payloads_small.json",
        "medium": "payloads_medium.json",
        "large": "payloads_large.json",
        "rag": "payloads_rag.json"
    }
    
    # If using one of the prepared datasets, load from file
    if dataset in dataset_files:
        dataset_path = script_dir / "test-data" / dataset_files[dataset]
        
        if dataset_path.exists():
            if dataset == "sharegpt":
                return load_sharegpt_prompts(str(dataset_path), num_prompts, input_size)
            else:
                # Use prepared payload files (small, medium, large, rag)
                return load_payload_prompts(str(dataset_path), num_prompts)
        else:
            print(f"Dataset not found at {dataset_path}")
            print("Using default prompts instead...")
    
    # Fallback to generated prompts
    if prompt_type == "simple":
        return ["Hello, how are you?"] * num_prompts
    
    elif prompt_type == "varied":
        return generate_default_prompts(num_prompts)
    
    elif prompt_type == "long":
        long_prompt = """Provide a comprehensive analysis of the following topic: 
        The impact of artificial intelligence on modern society, including its effects on 
        employment, healthcare, education, privacy, and ethics. Consider both positive 
        and negative aspects, and discuss potential future implications."""
        return [long_prompt] * num_prompts
    
    else:
        return ["Test prompt"] * num_prompts


async def main():
    parser = argparse.ArgumentParser(
        description="Benchmark model inference endpoint for TTFT, latency, and throughput"
    )
    parser.add_argument(
        "--endpoint",
        default="http://litellm.litellm.svc.ai-stack-cluster:4000/v1/chat/completions",
        help="Model endpoint URL (default: LiteLLM internal service endpoint)"
    )
    parser.add_argument(
        "--model",
        default="qwen3-4b-int4-ov",
        help="Model name to use in requests (default: qwen3-4b-int4-ov)"
    )
    parser.add_argument(
        "--api-key",
        default="sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef",
        help="API key for authentication (default: LiteLLM master key)"
    )
    parser.add_argument(
        "--requests",
        type=int,
        default=100,
        help="Total number of requests to send (default: 100)"
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=10,
        help="Number of concurrent requests (default: 10)"
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=100,
        help="Maximum tokens to generate per request (default: 100)"
    )
    parser.add_argument(
        "--prompt-type",
        choices=["simple", "varied", "long"],
        default="varied",
        help="Type of prompts to use (default: varied)"
    )
    parser.add_argument(
        "--output",
        default=f"benchmark_results_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json",
        help="Output file for detailed results (JSON)"
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Request timeout in seconds (default: 300)"
    )
    parser.add_argument(
        "--input-size",
        type=int,
        default=256,
        help="Input size (number of tokens) for prompts (default: 256)"
    )
    parser.add_argument(
        "--output-size",
        type=int,
        default=256,
        help="Output size (number of tokens) to generate (default: 256)"
    )
    parser.add_argument(
        "--dataset",
        type=str,
        default="small",
        choices=["sharegpt", "small", "medium", "large", "rag"],
        help="Dataset to use for prompts: sharegpt, small, medium, large, or rag (default: small)"
    )
    
    args = parser.parse_args()
    
    print(f"🚀 Starting benchmark...")
    print(f"   Endpoint: {args.endpoint}")
    print(f"   Model: {args.model}")
    print(f"   Requests: {args.requests}")
    print(f"   Concurrency: {args.concurrency}")
    print(f"   Input Size: {args.input_size} tokens")
    print(f"   Output Size: {args.output_size} tokens")
    print(f"   Dataset: {args.dataset}")
    print(f"   Prompt Type: {args.prompt_type}")
    
    # Generate prompts
    prompts = generate_test_prompts(
        num_prompts=args.requests, 
        prompt_type=args.prompt_type,
        dataset=args.dataset,
        input_size=args.input_size
    )
    
    # Initialize benchmark
    benchmark = ModelBenchmark(
        endpoint_url=args.endpoint,
        model_name=args.model,
        api_key=args.api_key,
        timeout=args.timeout
    )
    
    # Run benchmark
    print(f"\n⏳ Running benchmark with {args.concurrency} concurrent requests...")
    start_time = time.perf_counter()
    
    # Use output_size instead of max_tokens
    metrics_list = await benchmark.run_concurrent_requests(
        prompts=prompts,
        concurrency=args.concurrency,
        max_tokens=args.output_size
    )
    
    total_duration = time.perf_counter() - start_time
    
    # Aggregate and display results
    results = benchmark.aggregate_results(metrics_list, total_duration)
    if results:
        results.concurrency = args.concurrency
        benchmark.print_results(results, metrics_list)
        benchmark.save_results(results, metrics_list, args.output)
    else:
        print("\n❌ Benchmark failed - no successful requests")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
