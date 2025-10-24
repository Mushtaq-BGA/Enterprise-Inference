#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AI Stack - Local HTTPS Setup & Testing${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Function to print status
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check if running with sudo privileges (needed for /etc/hosts)
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        print_error "This script requires sudo privileges for /etc/hosts modification"
        echo "Please run: sudo -v"
        exit 1
    fi
}

# Get node internal IP
get_node_ip() {
    local ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    if [[ -z "$ip" ]]; then
        print_error "Could not detect node IP address"
        exit 1
    fi
    echo "$ip"
}

# Check if Istio gateway is running
check_istio_gateway() {
    print_info "Checking Istio ingress gateway..."
    
    if ! kubectl get deployment istio-ingressgateway -n istio-system &>/dev/null; then
        print_error "Istio ingress gateway not found. Please deploy Phase 1 first."
        exit 1
    fi
    
    local ready=$(kubectl get deployment istio-ingressgateway -n istio-system -o jsonpath='{.status.readyReplicas}')
    if [[ "$ready" -lt 1 ]]; then
        print_error "Istio ingress gateway is not ready"
        exit 1
    fi
    
    print_status "Istio ingress gateway is running"
}

# Get HTTPS NodePort
get_https_port() {
    local port=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
    if [[ -z "$port" ]]; then
        print_error "HTTPS port not found in Istio gateway service"
        exit 1
    fi
    echo "$port"
}

# Check if TLS certificate exists
check_tls_cert() {
    print_info "Checking TLS certificate..."
    
    if kubectl get secret aistack-tls-cert -n istio-system &>/dev/null; then
        print_status "TLS certificate 'aistack-tls-cert' already exists"
        return 0
    else
        print_warning "TLS certificate 'aistack-tls-cert' not found, will create it"
        return 1
    fi
}

# Create self-signed TLS certificate
create_tls_cert() {
    print_info "Creating self-signed TLS certificate for *.aistack.local..."
    
    # Create temporary directory
    local tmpdir=$(mktemp -d)
    cd "$tmpdir"
    
    # Generate private key
    openssl genrsa -out tls.key 2048 2>/dev/null
    
    # Generate certificate
    openssl req -new -x509 -key tls.key -out tls.crt -days 365 -subj "/O=AI Stack Inc./CN=*.aistack.local" \
        -addext "subjectAltName=DNS:*.aistack.local,DNS:aistack.local,DNS:*.kserve.aistack.local,DNS:litellm.aistack.local" 2>/dev/null
    
    # Create Kubernetes secret
    kubectl create secret tls aistack-tls-cert \
        --cert=tls.crt \
        --key=tls.key \
        -n istio-system
    
    # Cleanup
    cd - >/dev/null
    rm -rf "$tmpdir"
    
    print_status "TLS certificate created successfully"
}

# Check if Gateway is configured for HTTPS
check_gateway_https() {
    print_info "Checking Gateway HTTPS configuration..."
    
    local https_port=$(kubectl get gateway ai-stack-gateway -n istio-system -o jsonpath='{.spec.servers[?(@.port.protocol=="HTTPS")].port.number}')
    
    if [[ "$https_port" != "443" ]]; then
        print_error "Gateway 'ai-stack-gateway' is not configured for HTTPS on port 443"
        print_info "Please ensure your gateway has an HTTPS server configuration"
        exit 1
    fi
    
    local tls_mode=$(kubectl get gateway ai-stack-gateway -n istio-system -o jsonpath='{.spec.servers[?(@.port.protocol=="HTTPS")].tls.mode}')
    if [[ "$tls_mode" != "SIMPLE" ]]; then
        print_error "Gateway TLS mode is '$tls_mode', expected 'SIMPLE'"
        exit 1
    fi
    
    local credential=$(kubectl get gateway ai-stack-gateway -n istio-system -o jsonpath='{.spec.servers[?(@.port.protocol=="HTTPS")].tls.credentialName}')
    if [[ "$credential" != "aistack-tls-cert" ]]; then
        print_warning "Gateway uses credential '$credential', but we created 'aistack-tls-cert'"
        print_info "You may need to update the gateway configuration"
    fi
    
    print_status "Gateway HTTPS configuration looks good"
}

# Restart Istio gateway to pick up certificate changes
restart_gateway() {
    print_info "Restarting Istio ingress gateway to apply changes..."
    kubectl rollout restart deployment istio-ingressgateway -n istio-system
    kubectl rollout status deployment istio-ingressgateway -n istio-system --timeout=60s
    print_status "Gateway restarted successfully"
}

# Add entry to /etc/hosts
setup_hosts_file() {
    local node_ip=$1
    local hostname="litellm.aistack.local"
    
    print_info "Configuring /etc/hosts..."
    
    # Check if entry already exists
    if grep -q "^[^#]*$hostname" /etc/hosts; then
        # Entry exists, check if IP matches
        local existing_ip=$(grep "^[^#]*$hostname" /etc/hosts | awk '{print $1}')
        if [[ "$existing_ip" == "$node_ip" ]]; then
            print_status "/etc/hosts already has correct entry for $hostname"
            return 0
        else
            print_warning "Updating existing entry in /etc/hosts (old IP: $existing_ip)"
            sudo sed -i "s/^[^#]*$hostname.*/$node_ip $hostname/" /etc/hosts
        fi
    else
        # Add new entry
        echo "$node_ip $hostname" | sudo tee -a /etc/hosts >/dev/null
        print_status "Added $node_ip $hostname to /etc/hosts"
    fi
}

# Get LiteLLM API key
get_api_key() {
    local api_key=$(kubectl get secret litellm-config -n litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d)
    
    if [[ -z "$api_key" ]]; then
        # Try getting from deployment env
        api_key=$(kubectl get deployment litellm -n litellm -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}' 2>/dev/null)
    fi
    
    if [[ -z "$api_key" ]]; then
        print_warning "Could not retrieve LiteLLM API key, using default"
        echo "sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef"
    else
        echo "$api_key"
    fi
}

# Test HTTPS connection
test_https() {
    local node_ip=$1
    local https_port=$2
    local api_key=$3
    
    echo ""
    print_info "Testing HTTPS connections..."
    echo ""
    
    # Test 1: Health check
    echo -e "${BLUE}Test 1: Health Check${NC}"
    echo "Command: curl -k https://litellm.aistack.local:$https_port/health/readiness"
    
    local response=$(curl -k -s -w "\n%{http_code}" https://litellm.aistack.local:$https_port/health/readiness 2>&1)
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)
    
    if [[ "$http_code" == "200" ]]; then
        print_status "Health check passed (HTTP $http_code)"
        echo -e "${GREEN}Response:${NC} $(echo "$body" | jq -r '.status' 2>/dev/null || echo "$body")"
    else
        print_error "Health check failed (HTTP $http_code)"
        echo "Response: $body"
        return 1
    fi
    
    echo ""
    
    # Test 2: Models endpoint
    echo -e "${BLUE}Test 2: List Models API${NC}"
    echo "Command: curl -k https://litellm.aistack.local:$https_port/v1/models -H \"Authorization: Bearer <API_KEY>\""
    
    response=$(curl -k -s -w "\n%{http_code}" https://litellm.aistack.local:$https_port/v1/models \
        -H "Authorization: Bearer $api_key" 2>&1)
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    if [[ "$http_code" == "200" ]]; then
        print_status "Models API passed (HTTP $http_code)"
        local model_count=$(echo "$body" | jq -r '.data | length' 2>/dev/null || echo "0")
        echo -e "${GREEN}Available models:${NC} $model_count"
        echo "$body" | jq -r '.data[].id' 2>/dev/null | while read -r model; do
            echo "  - $model"
        done
    else
        print_error "Models API failed (HTTP $http_code)"
        echo "Response: $body"
        return 1
    fi
    
    echo ""
    
    # Test 3: TLS certificate details
    echo -e "${BLUE}Test 3: TLS Certificate Details${NC}"
    echo "Command: openssl s_client -connect litellm.aistack.local:$https_port -servername litellm.aistack.local"
    
    local cert_info=$(echo "" | openssl s_client -connect litellm.aistack.local:$https_port -servername litellm.aistack.local 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null)
    
    if [[ -n "$cert_info" ]]; then
        print_status "TLS certificate verified"
        echo "$cert_info" | while read -r line; do
            echo "  $line"
        done
    else
        print_warning "Could not verify TLS certificate details"
    fi
    
    echo ""
}

# Print access information
print_access_info() {
    local node_ip=$1
    local https_port=$2
    local api_key=$3
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}HTTPS Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}Access URLs:${NC}"
    echo "  HTTPS: https://litellm.aistack.local:$https_port"
    echo ""
    echo -e "${BLUE}API Key:${NC}"
    echo "  $api_key"
    echo ""
    echo -e "${BLUE}Example Usage:${NC}"
    echo "  # Health check"
    echo "  curl -k https://litellm.aistack.local:$https_port/health/readiness"
    echo ""
    echo "  # List models"
    echo "  curl -k https://litellm.aistack.local:$https_port/v1/models \\"
    echo "    -H \"Authorization: Bearer $api_key\""
    echo ""
    echo "  # Chat completion"
    echo "  curl -k https://litellm.aistack.local:$https_port/v1/chat/completions \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -H \"Authorization: Bearer $api_key\" \\"
    echo "    -d '{\"model\": \"qwen3-4b-int4-ov\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
    echo ""
    echo -e "${YELLOW}Note:${NC} The -k flag ignores self-signed certificate warnings."
    echo "      For browsers, you'll need to accept the security exception."
    echo ""
    echo -e "${BLUE}Remote Access:${NC}"
    echo "  To access from another machine, add this to the client's /etc/hosts:"
    echo "  $node_ip litellm.aistack.local"
    echo ""
}

# Main execution
main() {
    echo "This script will:"
    echo "  1. Check Istio gateway deployment"
    echo "  2. Create TLS certificate if needed"
    echo "  3. Configure gateway for HTTPS"
    echo "  4. Update /etc/hosts"
    echo "  5. Test HTTPS connectivity"
    echo ""
    
    # Check prerequisites
    check_sudo
    
    # Detect configuration
    print_info "Detecting cluster configuration..."
    NODE_IP=$(get_node_ip)
    print_status "Node IP: $NODE_IP"
    
    HTTPS_PORT=$(get_https_port)
    print_status "HTTPS NodePort: $HTTPS_PORT"
    
    API_KEY=$(get_api_key)
    print_status "API key retrieved"
    
    echo ""
    
    # Check and setup components
    check_istio_gateway
    
    # Certificate handling
    if ! check_tls_cert; then
        create_tls_cert
        restart_gateway
    fi
    
    check_gateway_https
    
    # Setup local access
    setup_hosts_file "$NODE_IP"
    
    # Wait a moment for everything to settle
    sleep 2
    
    # Run tests
    if test_https "$NODE_IP" "$HTTPS_PORT" "$API_KEY"; then
        print_access_info "$NODE_IP" "$HTTPS_PORT" "$API_KEY"
        exit 0
    else
        print_error "HTTPS tests failed. Please check the configuration."
        exit 1
    fi
}

# Run main function
main "$@"
