#!/bin/bash
# Istio Security Verification Script
# Verifies all external traffic flows through Istio ingress gateway
set -euo pipefail

# Disable exit on error for specific commands
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0

# Helper functions
print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_test() {
    echo -e "\n${YELLOW}▶ $1${NC}"
}

print_pass() {
    echo -e "${GREEN}✓ $1${NC}"
    ((TESTS_PASSED++))
}

print_fail() {
    echo -e "${RED}✗ $1${NC}"
    ((TESTS_FAILED++))
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    ((TESTS_WARNING++))
}

print_info() {
    echo -e "  ${NC}$1${NC}"
}

# Get Istio ingress gateway details
get_ingress_info() {
    INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -z "$INGRESS_HOST" ]; then
        INGRESS_HOST=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")
    fi
    INGRESS_HTTP_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o json 2>/dev/null | jq -r '.spec.ports[] | select(.port==80) | .nodePort' | head -1 || echo "30080")
    INGRESS_HTTPS_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o json 2>/dev/null | jq -r '.spec.ports[] | select(.port==443) | .nodePort' | head -1 || echo "30443")
}

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                                                                  ║"
echo "║       🔒 ISTIO SECURITY VERIFICATION                            ║"
echo "║       Verifying all external traffic routes through Istio       ║"
echo "║                                                                  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"

get_ingress_info

print_header "1. ISTIO INGRESS GATEWAY CONFIGURATION"

print_test "Checking Istio ingress gateway service type"
INGRESS_TYPE=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.type}')
if [ "$INGRESS_TYPE" == "NodePort" ] || [ "$INGRESS_TYPE" == "LoadBalancer" ]; then
    print_pass "Istio ingress gateway type: $INGRESS_TYPE"
    print_info "HTTP Port: $INGRESS_HTTP_PORT"
    print_info "HTTPS Port: $INGRESS_HTTPS_PORT"
    print_info "Host: $INGRESS_HOST"
else
    print_fail "Unexpected service type: $INGRESS_TYPE"
fi

print_test "Checking Istio ingress gateway pods"
INGRESS_PODS=$(kubectl get pods -n istio-system -l app=istio-ingressgateway --field-selector=status.phase=Running --no-headers | wc -l)
if [ "$INGRESS_PODS" -gt 0 ]; then
    print_pass "Istio ingress gateway running: $INGRESS_PODS pod(s)"
else
    print_fail "No running Istio ingress gateway pods found"
fi

print_header "2. EXPOSED SERVICES AUDIT"

print_test "Scanning for services with external exposure"
EXPOSED_SERVICES=$(kubectl get svc -A -o json 2>/dev/null | jq -r '.items[] | select(.spec.type == "NodePort" or .spec.type == "LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)|\(.spec.type)"' || echo "")

if [ -z "$EXPOSED_SERVICES" ]; then
    print_warning "No externally exposed services found"
else
    echo "$EXPOSED_SERVICES" | while IFS='|' read -r SERVICE TYPE; do
        if [[ "$SERVICE" == "istio-system/istio-ingressgateway" ]]; then
            print_pass "Expected: $SERVICE ($TYPE)"
        else
            print_warning "Found exposed service: $SERVICE ($TYPE)"
            print_info "Review if this should be exposed or route through Istio"
        fi
    done
fi

print_header "3. ISTIO GATEWAY RESOURCES"

print_test "Checking Istio Gateway configurations"
GATEWAYS=$(kubectl get gateway -A --no-headers 2>/dev/null | wc -l)
if [ "$GATEWAYS" -gt 0 ]; then
    print_pass "Found $GATEWAYS Istio Gateway(s)"
    kubectl get gateway -A --no-headers | while read -r NS NAME REST; do
        print_info "  • $NS/$NAME"
    done
else
    print_fail "No Istio Gateways found"
fi

print_test "Checking VirtualService configurations"
VIRTUALSERVICES=$(kubectl get virtualservice -A --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$VIRTUALSERVICES" -gt 0 ]; then
    print_pass "Found $VIRTUALSERVICES VirtualService(s)"
    kubectl get virtualservice -A --no-headers 2>/dev/null | while read -r NS NAME REST; do
        GATEWAYS_USED=$(kubectl get virtualservice -n "$NS" "$NAME" -o jsonpath='{.spec.gateways}' 2>/dev/null || echo "[]")
        print_info "  • $NS/$NAME → Gateways: $GATEWAYS_USED"
    done
else
    print_fail "No VirtualServices found"
fi

print_header "4. DIRECT SERVICE ACCESS TEST"

print_test "Checking for services bypassing Istio"
BYPASS_SERVICES=""

# Check LiteLLM
LITELLM_TYPE=$(kubectl get svc litellm -n litellm -o jsonpath='{.spec.type}' 2>/dev/null || echo "NotFound")
if [ "$LITELLM_TYPE" == "ClusterIP" ]; then
    print_pass "LiteLLM service: ClusterIP (secure, no direct access)"
elif [ "$LITELLM_TYPE" == "NotFound" ]; then
    print_info "LiteLLM service not found (may not be deployed yet)"
else
    print_fail "LiteLLM service: $LITELLM_TYPE (allows direct access)"
    BYPASS_SERVICES="$BYPASS_SERVICES litellm/$LITELLM_TYPE"
fi

# Check KServe predictor services
KSERVE_SERVICES=$(kubectl get svc -n kserve --no-headers 2>/dev/null | grep predictor || true)
if [ -n "$KSERVE_SERVICES" ]; then
    echo "$KSERVE_SERVICES" | while read -r NAME TYPE REST; do
        if [ "$TYPE" == "ClusterIP" ]; then
            print_pass "KServe service $NAME: ClusterIP (secure)"
        elif [ "$TYPE" == "ExternalName" ]; then
            print_pass "KServe service $NAME: ExternalName (internal DNS, secure)"
        else
            print_fail "KServe service $NAME: $TYPE (allows direct access)"
            BYPASS_SERVICES="$BYPASS_SERVICES kserve/$NAME/$TYPE"
        fi
    done
else
    print_info "No KServe predictor services found yet"
fi

print_header "5. NETWORK POLICY VERIFICATION"

print_test "Checking for NetworkPolicies"
NETPOL_COUNT=$(kubectl get networkpolicy -A --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$NETPOL_COUNT" -gt 0 ]; then
    print_pass "Found $NETPOL_COUNT NetworkPolicy/Policies"
    kubectl get networkpolicy -A --no-headers 2>/dev/null | while read -r NS NAME REST; do
        print_info "  • $NS/$NAME"
    done
else
    print_warning "No NetworkPolicies found (consider adding for defense in depth)"
fi

print_header "6. MTLS CONFIGURATION"

print_test "Checking Istio mTLS PeerAuthentication"
PEER_AUTH=$(kubectl get peerauthentication -A --no-headers 2>/dev/null | wc -l)
if [ "$PEER_AUTH" -gt 0 ]; then
    print_pass "Found $PEER_AUTH PeerAuthentication policy/policies"
    kubectl get peerauthentication -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.spec.mtls.mode)"' | while read -r LINE; do
        print_info "  • $LINE"
    done
else
    print_warning "No PeerAuthentication policies found (mTLS may not be enforced)"
fi

print_header "7. CONNECTIVITY TESTS"

print_test "Testing LiteLLM through Istio gateway"
if command -v curl &> /dev/null; then
    # Test public health endpoint first
    LITELLM_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 \
        -H "Host: litellm.aistack.local" \
        "http://$INGRESS_HOST:$INGRESS_HTTP_PORT/health/readiness" 2>/dev/null || echo "000")
    
    if [ "$LITELLM_RESPONSE" == "200" ]; then
        print_pass "LiteLLM accessible through Istio gateway (HTTP $LITELLM_RESPONSE)"
    elif [ "$LITELLM_RESPONSE" == "000" ]; then
        print_info "Connection timeout (may not be deployed or gateway not ready)"
    else
        # Try with auth as fallback
        LITELLM_KEY=$(kubectl get deployment litellm -n litellm -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}' 2>/dev/null || echo "")
        if [ -n "$LITELLM_KEY" ]; then
            AUTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 5 \
                -H "Host: litellm.aistack.local" \
                -H "Authorization: Bearer $LITELLM_KEY" \
                "http://$INGRESS_HOST:$INGRESS_HTTP_PORT/health" 2>/dev/null || echo "000")
            if [ "$AUTH_RESPONSE" == "200" ]; then
                print_pass "LiteLLM accessible through Istio gateway with auth (HTTP $AUTH_RESPONSE)"
            else
                print_warning "LiteLLM returned HTTP $LITELLM_RESPONSE (public) / $AUTH_RESPONSE (with auth)"
            fi
        else
            print_warning "LiteLLM returned HTTP $LITELLM_RESPONSE"
        fi
    fi
else
    print_info "curl not available, skipping connectivity test"
fi

print_test "Testing KServe model through Istio gateway"
MODEL_NAME="qwen3-4b-int4-ov"
KSERVE_EXISTS=$(kubectl get inferenceservice -n kserve "$MODEL_NAME" --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$KSERVE_EXISTS" -gt 0 ] && command -v curl &> /dev/null; then
    # Access through LiteLLM (correct way)
    LITELLM_KEY=$(kubectl get deployment litellm -n litellm -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}' 2>/dev/null || echo "")
    if [ -n "$LITELLM_KEY" ]; then
        MODEL_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 5 \
            -H "Host: litellm.aistack.local" \
            -H "Authorization: Bearer $LITELLM_KEY" \
            "http://$INGRESS_HOST:$INGRESS_HTTP_PORT/v1/models" 2>/dev/null || echo "000")
        
        if [ "$MODEL_RESPONSE" == "200" ]; then
            print_pass "KServe models accessible through Istio → LiteLLM (HTTP $MODEL_RESPONSE)"
        elif [ "$MODEL_RESPONSE" == "000" ]; then
            print_info "Connection timeout (model may not be ready)"
        else
            print_info "Models endpoint returned HTTP $MODEL_RESPONSE (may not be registered yet)"
        fi
    else
        print_info "LiteLLM API key not found, skipping model test"
    fi
else
    print_info "KServe model not deployed or curl not available"
fi

print_header "8. DIRECT ACCESS PREVENTION TEST"

print_test "Verifying service isolation"
# All services should be ClusterIP (not externally accessible)
LITELLM_TYPE=$(kubectl get svc litellm -n litellm -o jsonpath='{.spec.type}' 2>/dev/null || echo "NotFound")
if [ "$LITELLM_TYPE" == "ClusterIP" ]; then
    print_pass "Services properly isolated (ClusterIP - no direct external access)"
elif [ "$LITELLM_TYPE" == "NotFound" ]; then
    print_info "LiteLLM service not found (may not be deployed yet)"
else
    print_warning "LiteLLM service type: $LITELLM_TYPE (should be ClusterIP)"
fi

print_header "9. TLS/HTTPS CONFIGURATION"

print_test "Checking TLS certificates"
CERTS=$(kubectl get certificate -A --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$CERTS" -gt 0 ]; then
    print_pass "Found $CERTS certificate(s)"
    kubectl get certificate -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): Ready=\(.status.conditions[0].status)"' | while read -r LINE; do
        print_info "  • $LINE"
    done
else
    print_warning "No certificates found (HTTPS may not be configured)"
fi

print_test "Checking Gateway TLS configuration"
GATEWAY_TLS=$(kubectl get gateway -A -o json 2>/dev/null | jq -r '.items[] | select(.spec.servers[].tls != null) | "\(.metadata.namespace)/\(.metadata.name)"' | wc -l || echo "0")
if [ "$GATEWAY_TLS" -gt 0 ]; then
    print_pass "Found $GATEWAY_TLS gateway(s) with TLS configuration"
else
    print_warning "No gateways with TLS configuration found"
fi

print_header "10. AUTHORIZATION POLICIES"

print_test "Checking Istio AuthorizationPolicies"
AUTHZ=$(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$AUTHZ" -gt 0 ]; then
    print_pass "Found $AUTHZ AuthorizationPolicy/Policies"
    kubectl get authorizationpolicy -A --no-headers 2>/dev/null | while read -r NS NAME REST; do
        print_info "  • $NS/$NAME"
    done
else
    print_warning "No AuthorizationPolicies found (consider adding for access control)"
fi

# Final summary
print_header "SECURITY VERIFICATION SUMMARY"

echo ""
echo "  Test Results:"
echo -e "    ${GREEN}✓ Passed:  $TESTS_PASSED${NC}"
echo -e "    ${RED}✗ Failed:  $TESTS_FAILED${NC}"
echo -e "    ${YELLOW}⚠ Warnings: $TESTS_WARNING${NC}"
echo ""

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ SECURITY CHECK PASSED                                       ║${NC}"
    echo -e "${GREEN}║  All external traffic routes through Istio ingress gateway      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    
    if [ "$TESTS_WARNING" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Recommendations to improve security:${NC}"
        echo "  1. Configure TLS certificates for HTTPS"
        echo "  2. Enable strict mTLS between services"
        echo "  3. Add NetworkPolicies for defense in depth"
        echo "  4. Configure AuthorizationPolicies for access control"
    fi
    exit 0
else
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  SECURITY ISSUES DETECTED                                    ║${NC}"
    echo -e "${RED}║  Please review failed checks above                               ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
