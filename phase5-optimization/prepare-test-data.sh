#!/bin/bash
# Prepare realistic test data from ShareGPT dataset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/test-data"
SHAREGPT_URL="https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json"

echo "========================================="
echo "Preparing Realistic Test Data"
echo "========================================="

# Create data directory
mkdir -p "$DATA_DIR"

# Download ShareGPT dataset if not exists
if [ ! -f "$DATA_DIR/ShareGPT_V3_unfiltered_cleaned_split.json" ]; then
    echo "Downloading ShareGPT dataset..."
    echo "Source: $SHAREGPT_URL"
    
    if command -v wget &> /dev/null; then
        wget -O "$DATA_DIR/ShareGPT_V3_unfiltered_cleaned_split.json" "$SHAREGPT_URL"
    elif command -v curl &> /dev/null; then
        curl -L -o "$DATA_DIR/ShareGPT_V3_unfiltered_cleaned_split.json" "$SHAREGPT_URL"
    else
        echo "Error: wget or curl required to download dataset"
        exit 1
    fi
    
    echo "✓ ShareGPT dataset downloaded"
else
    echo "✓ ShareGPT dataset already exists"
fi

# Install jq if not available (for JSON processing)
if ! command -v jq &> /dev/null; then
    echo "Installing jq for JSON processing..."
    sudo apt-get update && sudo apt-get install -y jq
fi

# Create test payload samples
echo ""
echo "Creating test payload samples..."

# Extract samples of different sizes
python3 - <<'PYTHON'
import json
import random
import os

script_dir = os.path.dirname(os.path.abspath(__file__))
data_dir = os.path.join(script_dir, "test-data")
sharegpt_file = os.path.join(data_dir, "ShareGPT_V3_unfiltered_cleaned_split.json")

# Load ShareGPT data
print("Loading ShareGPT dataset...")
with open(sharegpt_file, 'r') as f:
    data = json.load(f)

print(f"Loaded {len(data)} conversations")

# Function to estimate tokens (rough approximation: 1 token ≈ 4 characters)
def estimate_tokens(text):
    return len(text) // 4

# Extract conversations of different sizes
small_samples = []  # 50-150 tokens
medium_samples = []  # 150-500 tokens
large_samples = []  # 500-1500 tokens
rag_samples = []  # 1500+ tokens (multi-turn)

for conv in data:
    if 'conversations' not in conv:
        continue
    
    # Get first user message
    user_messages = [msg for msg in conv['conversations'] if msg.get('from') == 'human']
    if not user_messages:
        continue
    
    first_msg = user_messages[0]['value']
    tokens = estimate_tokens(first_msg)
    
    sample = {
        "content": first_msg,
        "tokens": tokens
    }
    
    if 50 <= tokens <= 150 and len(small_samples) < 100:
        small_samples.append(sample)
    elif 150 <= tokens <= 500 and len(medium_samples) < 100:
        medium_samples.append(sample)
    elif 500 <= tokens <= 1500 and len(large_samples) < 100:
        large_samples.append(sample)
    elif tokens > 1500 and len(rag_samples) < 100:
        # For RAG simulation, combine multiple turns
        all_text = " ".join([msg['value'] for msg in conv['conversations'][:3]])
        rag_samples.append({
            "content": all_text,
            "tokens": estimate_tokens(all_text)
        })

# Save categorized samples
categories = {
    "small": small_samples,
    "medium": medium_samples,
    "large": large_samples,
    "rag": rag_samples
}

for category, samples in categories.items():
    output_file = os.path.join(data_dir, f"payloads_{category}.json")
    with open(output_file, 'w') as f:
        json.dump(samples, f, indent=2)
    print(f"✓ Created {category} payloads: {len(samples)} samples (avg {sum(s['tokens'] for s in samples)//len(samples) if samples else 0} tokens)")

print("\n✓ Test data preparation complete!")
PYTHON

echo ""
echo "========================================="
echo "Test Data Ready"
echo "========================================="
echo "Location: $DATA_DIR"
echo ""
echo "Available payload types:"
echo "  - small:  50-150 tokens (quick responses)"
echo "  - medium: 150-500 tokens (typical queries)"
echo "  - large:  500-1500 tokens (complex queries)"
echo "  - rag:    1500+ tokens (RAG/multi-turn context)"
echo ""
echo "Use with load testing scripts:"
echo "  PAYLOAD_TYPE=medium ./load-test-baseline.sh"
echo ""
