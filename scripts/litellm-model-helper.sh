#!/bin/bash
# LiteLLM Model Helper - CLI and interactive tool for managing models and LiteLLM
# Usage: ./litellm-model-helper.sh [command] [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib/cluster-domain.sh"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_error() { printf "${RED}✗ %s${NC}\n" "$1" >&2; }
print_info() { printf "${YELLOW}ℹ %s${NC}\n" "$1"; }
print_success() { printf "${GREEN}✓ %s${NC}\n" "$1"; }
print_header() { printf "${CYAN}%s${NC}\n" "$1"; }

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "Missing required command: $1"
        exit 1
    fi
}

find_free_port() {
    local port=${1:-4000}
    local max_port=${2:-4100}
    while [ "$port" -le "$max_port" ]; do
        if ! lsof -i ":$port" >/dev/null 2>&1; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    return 1
}

require_command kubectl

LITELLM_NS="${LITELLM_NAMESPACE:-litellm}"
KSERVE_NS="${KSERVE_NAMESPACE:-kserve}"
CLUSTER_DOMAIN="$(ensure_cluster_domain)"

# Check if LiteLLM is deployed
check_litellm() {
    if ! kubectl get ns "$LITELLM_NS" >/dev/null 2>&1; then
        print_error "Namespace '$LITELLM_NS' not found. Deploy Phase 3 first."
        return 1
    fi
    if ! kubectl get deployment litellm -n "$LITELLM_NS" >/dev/null 2>&1; then
        print_error "LiteLLM deployment not found in namespace '$LITELLM_NS'."
        return 1
    fi
    return 0
}

# Get LiteLLM credentials
get_credentials() {
    MASTER_KEY=$(kubectl get deployment litellm -n "$LITELLM_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MASTER_KEY")].value}' 2>/dev/null || true)
    UI_USERNAME=$(kubectl get deployment litellm -n "$LITELLM_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="UI_USERNAME")].value}' 2>/dev/null || echo "admin")
    UI_PASSWORD=$(kubectl get deployment litellm -n "$LITELLM_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="UI_PASSWORD")].value}' 2>/dev/null || echo "admin")
}

# Function 1: Show credentials
show_credentials() {
    echo ""
    print_header "========================================="
    print_header "LiteLLM Credentials"
    print_header "========================================="
    echo ""
    
    get_credentials
    
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
    HTTP_NODE_PORT=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null || echo "")
    
    cat <<EOF
Dashboard Access:
  Local (port-forward): http://localhost:4000/ui
  Istio Ingress:        http://litellm.aistack.local:$HTTP_NODE_PORT/ui

Authentication:
  Username:  $UI_USERNAME
  Password:  $UI_PASSWORD
  API Token: $MASTER_KEY

API Endpoint:
  Local:     http://localhost:4000/v1
  Internal:  http://litellm.$LITELLM_NS.svc.$CLUSTER_DOMAIN:4000/v1

Notes:
  • Add "$NODE_IP litellm.aistack.local" to /etc/hosts for Istio Ingress
  • Use API Token as Bearer token for API requests
  • Cluster domain: $CLUSTER_DOMAIN

EOF
}

# Function 2: List registered models
list_models() {
    echo ""
    print_header "========================================="
    print_header "Registered Models in LiteLLM"
    print_header "========================================="
    echo ""
    
    print_info "Reading models from LiteLLM ConfigMap..."
    
    if ! kubectl get configmap litellm-config -n "$LITELLM_NS" >/dev/null 2>&1; then
        print_error "ConfigMap 'litellm-config' not found"
        return 1
    fi
    
    MODELS=$(kubectl get configmap litellm-config -n "$LITELLM_NS" -o jsonpath='{.data.config\.yaml}' | grep -A 5 "model_name:" || true)
    
    if [ -z "$MODELS" ]; then
        print_info "No models registered yet"
        echo ""
        return 0
    fi
    
    echo "Models:"
    kubectl get configmap litellm-config -n "$LITELLM_NS" -o jsonpath='{.data.config\.yaml}' | \
        grep -A 10 "model_list:" | grep -E "^\s+- model_name:" | \
        awk '{count++; printf "  %d. %s\n", count, $3}'
    
    echo ""
    echo "Endpoints:"
    kubectl get configmap litellm-config -n "$LITELLM_NS" -o jsonpath='{.data.config\.yaml}' | \
        grep -E "api_base:" | awk '{printf "     %s\n", $2}'
    
    echo ""
}

# Function 3: Add model to KServe and auto-register
add_model() {
    echo ""
    print_header "========================================="
    print_header "Add Model to KServe"
    print_header "========================================="
    echo ""
    
    print_info "This will create an InferenceService in KServe and auto-register it in LiteLLM"
    echo ""
    
    read -p "Enter model name (e.g., qwen3-4b-int4-ov): " MODEL_NAME
    if [ -z "$MODEL_NAME" ]; then
        print_error "Model name cannot be empty"
        return 1
    fi
    
    read -p "Enter HuggingFace model ID (e.g., OpenVINO/Qwen3-4B-int4-ov): " HF_MODEL_ID
    if [ -z "$HF_MODEL_ID" ]; then
        print_error "HuggingFace model ID cannot be empty"
        return 1
    fi
    
    read -p "CPU request (default: 8): " CPU_REQUEST
    CPU_REQUEST=${CPU_REQUEST:-8}
    
    read -p "CPU limit (default: 32): " CPU_LIMIT
    CPU_LIMIT=${CPU_LIMIT:-32}
    
    read -p "Memory request (default: 16Gi): " MEM_REQUEST
    MEM_REQUEST=${MEM_REQUEST:-16Gi}
    
    read -p "Memory limit (default: 64Gi): " MEM_LIMIT
    MEM_LIMIT=${MEM_LIMIT:-64Gi}
    
    echo ""
    print_info "Creating InferenceService manifest..."
    
    cat > "/tmp/${MODEL_NAME}-inferenceservice.yaml" <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ${MODEL_NAME}
  namespace: ${KSERVE_NS}
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 3
    scaleTarget: 10
    scaleMetric: concurrency
    model:
      modelFormat:
        name: huggingface
      runtime: kserve-openvino-hf
      resources:
        requests:
          cpu: "${CPU_REQUEST}"
          memory: "${MEM_REQUEST}"
        limits:
          cpu: "${CPU_LIMIT}"
          memory: "${MEM_LIMIT}"
      args:
        - --source_model=${HF_MODEL_ID}
        - --model_repository_path=/tmp
        - --task=text_generation
        - --target_device=CPU
EOF
    
    print_info "Applying InferenceService..."
    kubectl apply -f "/tmp/${MODEL_NAME}-inferenceservice.yaml"
    
    echo ""
    print_info "Waiting for InferenceService to be ready (this may take 1-2 minutes)..."
    kubectl wait --for=condition=Ready inferenceservice/${MODEL_NAME} -n ${KSERVE_NS} --timeout=300s || {
        print_error "InferenceService failed to become ready. Check logs:"
        echo "  kubectl describe inferenceservice ${MODEL_NAME} -n ${KSERVE_NS}"
        return 1
    }
    
    print_success "InferenceService created successfully"
    echo ""
    print_info "Running auto-registration..."
    
    cd "$REPO_ROOT/phase4-model-watcher"
    AUTO_CONFIRM=true ./discover-and-configure.sh
    
    echo ""
    print_success "Model ${MODEL_NAME} deployed and registered!"
    echo ""
}

# Function 4: Unregister model
unregister_model() {
    echo ""
    print_header "========================================="
    print_header "Unregister Model"
    print_header "========================================="
    echo ""
    
    print_info "Current registered models:"
    list_models
    
    read -p "Enter model name to unregister (or 'cancel' to abort): " MODEL_NAME
    if [ -z "$MODEL_NAME" ] || [ "$MODEL_NAME" = "cancel" ]; then
        print_info "Operation cancelled"
        return 0
    fi
    
    echo ""
    read -p "Also delete InferenceService from KServe? (yes/no): " DELETE_ISVC
    
    if [ "$DELETE_ISVC" = "yes" ]; then
        if kubectl get inferenceservice "$MODEL_NAME" -n "$KSERVE_NS" >/dev/null 2>&1; then
            print_info "Deleting InferenceService ${MODEL_NAME}..."
            kubectl delete inferenceservice "$MODEL_NAME" -n "$KSERVE_NS"
            print_success "InferenceService deleted"
        else
            print_info "InferenceService ${MODEL_NAME} not found in namespace ${KSERVE_NS}"
        fi
    fi
    
    echo ""
    print_info "Re-running model discovery to update LiteLLM configuration..."
    cd "$REPO_ROOT/phase4-model-watcher"
    AUTO_CONFIRM=true ./discover-and-configure.sh
    
    print_success "Model ${MODEL_NAME} unregistered from LiteLLM"
    echo ""
}

# Function 5: Test model
test_model() {
    echo ""
    print_header "========================================="
    print_header "Test Model"
    print_header "========================================="
    echo ""
    
    print_info "Available models:"
    list_models
    
    read -p "Enter model name to test: " MODEL_NAME
    if [ -z "$MODEL_NAME" ]; then
        print_error "Model name cannot be empty"
        return 1
    fi
    
    read -p "Enter test prompt (default: 'What is 2+2? Answer briefly.'): " TEST_PROMPT
    TEST_PROMPT=${TEST_PROMPT:-"What is 2+2? Answer briefly."}
    
    read -p "Max tokens (default: 50): " MAX_TOKENS
    MAX_TOKENS=${MAX_TOKENS:-50}
    
    get_credentials
    
    echo ""
    print_info "Sending request to model: ${MODEL_NAME}"
    print_info "Prompt: ${TEST_PROMPT}"
    echo ""
    
    RESPONSE=$(curl -s -X POST http://localhost:4000/v1/chat/completions \
        -H "Authorization: Bearer ${MASTER_KEY}" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"${TEST_PROMPT}\"}],\"max_tokens\":${MAX_TOKENS}}")
    
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$ERROR" ]; then
        print_error "Request failed: $ERROR"
        echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if [ -z "$CONTENT" ]; then
        print_error "No response content received"
        echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    print_success "Model responded successfully!"
    echo ""
    print_header "Response:"
    echo "$CONTENT"
    echo ""
    
    print_info "Full response details:"
    echo "$RESPONSE" | jq '{
        model: .model,
        usage: .usage,
        finish_reason: .choices[0].finish_reason
    }' 2>/dev/null
    echo ""
}

# Function 6: Show help
show_help() {
    echo ""
    print_header "========================================="
    print_header "LiteLLM Model Helper - Help"
    print_header "========================================="
    echo ""
    
    cat <<EOF
CLI Usage:
  $(basename "$0") [command] [options]

Commands:
  credentials                 Show LiteLLM credentials and endpoints
  list                       List all registered models
  add <model-name> <hf-id>   Add model to KServe and register in LiteLLM
  test <model-name>          Test a model with inference request
  delete <model-name>        Delete model from KServe and unregister
  interactive                Launch interactive menu (default)
  help                       Show this help message

Options for 'add' command:
  --cpu-request <value>      CPU request (default: 8)
  --cpu-limit <value>        CPU limit (default: 32)
  --mem-request <value>      Memory request (default: 16Gi)
  --mem-limit <value>        Memory limit (default: 64Gi)

Options for 'test' command:
  --prompt <text>            Test prompt (default: "What is 2+2? Answer briefly.")
  --max-tokens <number>      Max tokens (default: 50)

Examples:
  # Show credentials
  $(basename "$0") credentials

  # List models
  $(basename "$0") list

  # Add a model with default resources
  $(basename "$0") add phi-4-mini OpenVINO/Phi-4-mini-instruct-int8-ov

  # Add a model with custom resources
  $(basename "$0") add qwen3-4b OpenVINO/Qwen3-4B-int4-ov \\
    --cpu-request 4 --cpu-limit 16 --mem-request 8Gi --mem-limit 32Gi

  # Test a model
  $(basename "$0") test phi-4-mini --prompt "Hello, how are you?" --max-tokens 100

  # Delete a model
  $(basename "$0") delete phi-4-mini

  # Interactive mode
  $(basename "$0")
  $(basename "$0") interactive

API Usage:
  # List models via API
  curl http://localhost:4000/v1/models \\
    -H 'Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef'
  
  # Test chat completion
  curl -X POST http://localhost:4000/v1/chat/completions \\
    -H 'Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef' \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"<model-name>","messages":[{"role":"user","content":"Hello"}]}'

Configuration:
  LiteLLM Namespace: $LITELLM_NS
  KServe Namespace:  $KSERVE_NS
  Cluster Domain:    $CLUSTER_DOMAIN
  MASTER_KEY:        sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef

EOF
}

# CLI wrapper functions
cli_add_model() {
    local MODEL_NAME="$1"
    local HF_MODEL_ID="$2"
    shift 2
    
    # Default values
    local CPU_REQUEST="8"
    local CPU_LIMIT="32"
    local MEM_REQUEST="16Gi"
    local MEM_LIMIT="64Gi"
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cpu-request)
                CPU_REQUEST="$2"
                shift 2
                ;;
            --cpu-limit)
                CPU_LIMIT="$2"
                shift 2
                ;;
            --mem-request)
                MEM_REQUEST="$2"
                shift 2
                ;;
            --mem-limit)
                MEM_LIMIT="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    echo ""
    print_header "========================================="
    print_header "Add Model to KServe"
    print_header "========================================="
    echo ""
    
    print_info "Model Name: $MODEL_NAME"
    print_info "HuggingFace ID: $HF_MODEL_ID"
    print_info "Resources: ${CPU_REQUEST}-${CPU_LIMIT} CPU, ${MEM_REQUEST}-${MEM_LIMIT} Memory"
    echo ""
    
    print_info "Creating InferenceService manifest..."
    
    cat > "/tmp/${MODEL_NAME}-inferenceservice.yaml" <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ${MODEL_NAME}
  namespace: ${KSERVE_NS}
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 3
    scaleTarget: 10
    scaleMetric: concurrency
    model:
      modelFormat:
        name: huggingface
      runtime: kserve-openvino-hf
      resources:
        requests:
          cpu: "${CPU_REQUEST}"
          memory: "${MEM_REQUEST}"
        limits:
          cpu: "${CPU_LIMIT}"
          memory: "${MEM_LIMIT}"
      args:
        - --source_model=${HF_MODEL_ID}
        - --model_repository_path=/tmp
        - --task=text_generation
        - --target_device=CPU
EOF
    
    print_info "Applying InferenceService..."
    kubectl apply -f "/tmp/${MODEL_NAME}-inferenceservice.yaml"
    
    echo ""
    print_info "Waiting for InferenceService to be ready (this may take 1-2 minutes)..."
    kubectl wait --for=condition=Ready inferenceservice/${MODEL_NAME} -n ${KSERVE_NS} --timeout=300s || {
        print_error "InferenceService failed to become ready. Check logs:"
        echo "  kubectl describe inferenceservice ${MODEL_NAME} -n ${KSERVE_NS}"
        return 1
    }
    
    print_success "InferenceService created successfully"
    echo ""
    print_info "Running auto-registration..."
    
    cd "$REPO_ROOT/phase4-model-watcher"
    AUTO_CONFIRM=true ./discover-and-configure.sh
    
    echo ""
    print_success "Model ${MODEL_NAME} deployed and registered!"
    echo ""
}

cli_test_model() {
    local MODEL_NAME="$1"
    shift
    
    local TEST_PROMPT="What is 2+2? Answer briefly."
    local MAX_TOKENS="50"
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --prompt)
                TEST_PROMPT="$2"
                shift 2
                ;;
            --max-tokens)
                MAX_TOKENS="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    echo ""
    print_header "========================================="
    print_header "Test Model"
    print_header "========================================="
    echo ""
    
    get_credentials
    
    print_info "Model: ${MODEL_NAME}"
    print_info "Prompt: ${TEST_PROMPT}"
    print_info "Max tokens: ${MAX_TOKENS}"
    echo ""
    
    RESPONSE=$(curl -s -X POST http://localhost:4000/v1/chat/completions \
        -H "Authorization: Bearer ${MASTER_KEY}" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"${TEST_PROMPT}\"}],\"max_tokens\":${MAX_TOKENS}}")
    
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$ERROR" ]; then
        print_error "Request failed: $ERROR"
        echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if [ -z "$CONTENT" ]; then
        print_error "No response content received"
        echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    print_success "Model responded successfully!"
    echo ""
    print_header "Response:"
    echo "$CONTENT"
    echo ""
    
    print_info "Usage details:"
    echo "$RESPONSE" | jq '{
        model: .model,
        usage: .usage,
        finish_reason: .choices[0].finish_reason
    }' 2>/dev/null
    echo ""
}

cli_delete_model() {
    local MODEL_NAME="$1"
    
    echo ""
    print_header "========================================="
    print_header "Delete Model"
    print_header "========================================="
    echo ""
    
    if kubectl get inferenceservice "$MODEL_NAME" -n "$KSERVE_NS" >/dev/null 2>&1; then
        print_info "Deleting InferenceService ${MODEL_NAME}..."
        kubectl delete inferenceservice "$MODEL_NAME" -n "$KSERVE_NS"
        print_success "InferenceService deleted"
    else
        print_info "InferenceService ${MODEL_NAME} not found in namespace ${KSERVE_NS}"
    fi
    
    echo ""
    print_info "Re-running model discovery to update LiteLLM configuration..."
    cd "$REPO_ROOT/phase4-model-watcher"
    AUTO_CONFIRM=true ./discover-and-configure.sh
    
    print_success "Model ${MODEL_NAME} deleted and unregistered from LiteLLM"
    echo ""
}

# Main menu
show_menu() {
    echo ""
    print_header "========================================="
    print_header "LiteLLM Model Helper"
    print_header "========================================="
    echo ""
    echo "  1) Show LiteLLM Credentials"
    echo "  2) List Registered Models"
    echo "  3) Add Model to KServe (and auto-register)"
    echo "  4) Unregister Model"
    echo "  5) Test Model"
    echo "  6) Help"
    echo "  7) Exit"
    echo ""
}

# Main execution
main() {
    # Check if LiteLLM is deployed
    if ! check_litellm; then
        exit 1
    fi
    
    # CLI mode
    if [ $# -gt 0 ]; then
        COMMAND="$1"
        shift
        
        case "$COMMAND" in
            credentials|creds)
                show_credentials
                ;;
            list|ls)
                list_models
                ;;
            add|create)
                if [ $# -lt 2 ]; then
                    print_error "Usage: $(basename "$0") add <model-name> <huggingface-model-id> [options]"
                    exit 1
                fi
                cli_add_model "$@"
                ;;
            test)
                if [ $# -lt 1 ]; then
                    print_error "Usage: $(basename "$0") test <model-name> [options]"
                    exit 1
                fi
                cli_test_model "$@"
                ;;
            delete|rm|remove)
                if [ $# -lt 1 ]; then
                    print_error "Usage: $(basename "$0") delete <model-name>"
                    exit 1
                fi
                cli_delete_model "$1"
                ;;
            help|--help|-h)
                show_help
                ;;
            interactive|menu)
                # Fall through to interactive mode
                ;;
            *)
                print_error "Unknown command: $COMMAND"
                echo ""
                show_help
                exit 1
                ;;
        esac
        
        # Exit after CLI command (unless interactive mode requested)
        if [ "$COMMAND" != "interactive" ] && [ "$COMMAND" != "menu" ]; then
            exit 0
        fi
    fi
    
    # Interactive menu loop
    while true; do
        show_menu
        read -p "Select option (1-7): " CHOICE
        
        case $CHOICE in
            1)
                show_credentials
                read -p "Press Enter to continue..."
                ;;
            2)
                list_models
                read -p "Press Enter to continue..."
                ;;
            3)
                add_model
                read -p "Press Enter to continue..."
                ;;
            4)
                unregister_model
                read -p "Press Enter to continue..."
                ;;
            5)
                test_model
                read -p "Press Enter to continue..."
                ;;
            6)
                show_help
                read -p "Press Enter to continue..."
                ;;
            7)
                echo ""
                print_info "Goodbye!"
                echo ""
                exit 0
                ;;
            *)
                print_error "Invalid option. Please select 1-7."
                sleep 1
                ;;
        esac
    done
}

main "$@"
