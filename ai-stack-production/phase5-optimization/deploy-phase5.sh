#!/bin/bash
# Deploy Phase 5: High Concurrency Tuning
# This phase contains documentation and load testing tools
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Phase 5: High Concurrency Optimization"
echo "========================================="

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

print_info "Phase 5 contains optimization guidelines and load testing tools."
print_info "All performance optimizations are already applied in Phases 1-4."
echo ""

# Check if stack is deployed
print_info "Checking if AI stack is deployed..."

if ! kubectl get deployment litellm -n litellm &> /dev/null; then
    print_error "LiteLLM not found. Please deploy phases 1-4 first."
    exit 1
fi

if ! kubectl get deployment istiod -n istio-system &> /dev/null; then
    print_error "Istio not found. Please deploy phase 1 first."
    exit 1
fi

print_success "AI stack is deployed"
echo ""

# Show current configuration
print_info "Current Configuration:"
echo ""
echo "LiteLLM:"
kubectl get deployment litellm -n litellm -o jsonpath='  Replicas: {.spec.replicas}' && echo ""
kubectl get deployment litellm -n litellm -o jsonpath='  CPU Limit: {.spec.template.spec.containers[0].resources.limits.cpu}' && echo ""
kubectl get deployment litellm -n litellm -o jsonpath='  Memory Limit: {.spec.template.spec.containers[0].resources.limits.memory}' && echo ""
echo ""
echo "HPA:"
kubectl get hpa litellm-hpa -n litellm -o jsonpath='  Min Replicas: {.spec.minReplicas}' && echo ""
kubectl get hpa litellm-hpa -n litellm -o jsonpath='  Max Replicas: {.spec.maxReplicas}' && echo ""
echo ""

# Make scripts executable
chmod +x "$SCRIPT_DIR"/load-test-*.sh

print_success "Load testing scripts are ready"
echo ""

# Show available tools
echo "========================================="
echo "Available Tools"
echo "========================================="
echo ""
echo "1. Baseline Performance Test:"
echo "   ./load-test-baseline.sh"
echo "   - Tests with 100 concurrent users for 60 seconds"
echo "   - Measures baseline latency and throughput"
echo ""
echo "2. Ramp-up Concurrency Test:"
echo "   ./load-test-rampup.sh"
echo "   - Gradually increases load: 100 → 250 → 500 → 750 → 1000"
echo "   - Validates autoscaling behavior"
echo ""
echo "3. Monitor Autoscaling (Optional):"
echo "   ./monitor-autoscaling.sh"
echo "   - Real-time replica count and CPU usage"
echo "   - Press Ctrl+C to stop monitoring"
echo ""
echo "4. View Optimization Guide:"
echo "   cat README.md"
echo "   - Detailed tuning recommendations"
echo "   - Monitoring queries"
echo "   - Troubleshooting guide"
echo ""

# Check if load testing tools are installed
print_info "Checking for load testing tools..."

if command -v hey &> /dev/null; then
    print_success "hey is installed"
elif command -v wrk &> /dev/null; then
    print_success "wrk is installed"
elif command -v ab &> /dev/null; then
    print_success "Apache Bench (ab) is installed"
else
    print_error "No load testing tools found"
    echo ""
    echo "Install one of the following:"
    echo ""
    echo "1. hey (recommended):"
    echo "   go install github.com/rakyll/hey@latest"
    echo ""
    echo "2. wrk:"
    echo "   sudo apt-get install wrk"
    echo ""
    echo "3. Apache Bench:"
    echo "   sudo apt-get install apache2-utils"
fi

echo ""
echo "========================================="
echo "Phase 5 Setup Complete"
echo "========================================="
print_success "✓ Optimization documentation available"
print_success "✓ Load testing scripts ready"
print_success "✓ Performance tuning already applied"
echo ""
print_info "Recommended Next Steps:"
echo "  1. Review README.md for optimization details"
echo "  2. Run baseline load test: ./load-test-baseline.sh"
echo "  3. Run ramp-up test: ./load-test-rampup.sh"
echo "  4. Monitor metrics and adjust as needed"
echo ""
print_info "All phases complete! Your AI stack is ready for production."
echo ""
