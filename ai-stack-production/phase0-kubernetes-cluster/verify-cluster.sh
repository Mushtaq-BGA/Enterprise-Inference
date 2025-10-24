#!/bin/bash
# Verify Kubernetes Cluster Installation
set -euo pipefail

echo "========================================="
echo "Kubernetes Cluster Verification"
echo "========================================="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

ERRORS=0

# Test 1: kubectl access
print_info "Test 1: Checking kubectl access..."
if kubectl cluster-info &> /dev/null; then
    print_success "kubectl can access the cluster"
    kubectl cluster-info
else
    print_error "kubectl cannot access the cluster"
    ((ERRORS++))
fi
echo ""

# Test 2: Node status
print_info "Test 2: Checking node status..."
NODES_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
NODES_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$NODES_READY" -eq "$NODES_TOTAL" ] && [ "$NODES_TOTAL" -gt 0 ]; then
    print_success "All $NODES_TOTAL nodes are Ready"
    kubectl get nodes -o wide
else
    print_error "Some nodes are not Ready ($NODES_READY/$NODES_TOTAL)"
    kubectl get nodes
    ((ERRORS++))
fi
echo ""

# Test 3: System pods
print_info "Test 3: Checking system pods..."
PODS_RUNNING=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")
PODS_TOTAL=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$PODS_RUNNING" -eq "$PODS_TOTAL" ] && [ "$PODS_TOTAL" -gt 0 ]; then
    print_success "All system pods are Running ($PODS_RUNNING/$PODS_TOTAL)"
else
    print_error "Some system pods are not Running ($PODS_RUNNING/$PODS_TOTAL)"
    kubectl get pods -n kube-system | grep -v "Running"
    ((ERRORS++))
fi
echo ""

# Test 4: DNS
print_info "Test 4: Testing DNS resolution..."
if kubectl run dns-test --image=busybox:1.28 --rm -i --restart=Never --command -- nslookup kubernetes.default &> /dev/null; then
    print_success "DNS resolution is working"
else
    print_error "DNS resolution failed"
    ((ERRORS++))
fi
echo ""

# Test 5: Storage Class
print_info "Test 5: Checking storage class..."
if kubectl get storageclass 2>/dev/null | grep -q "default"; then
    print_success "Default storage class is configured"
    kubectl get storageclass
else
    print_error "No default storage class found"
    ((ERRORS++))
fi
echo ""

# Test 6: Metrics Server
print_info "Test 6: Testing metrics-server..."
if kubectl top nodes &> /dev/null; then
    print_success "Metrics-server is working"
    kubectl top nodes
else
    print_error "Metrics-server not working (this may take a few minutes after installation)"
    echo "Try again in a few minutes or check: kubectl get pods -n kube-system -l k8s-app=metrics-server"
fi
echo ""

# Test 7: API Server
print_info "Test 7: Testing API server..."
if kubectl get --raw /healthz &> /dev/null; then
    print_success "API server is healthy"
else
    print_error "API server health check failed"
    ((ERRORS++))
fi
echo ""

# Test 8: Pod Creation
print_info "Test 8: Testing pod creation..."
if kubectl run test-pod --image=nginx:alpine --rm -i --restart=Never --command -- echo "Success" &> /dev/null; then
    print_success "Pod creation is working"
else
    print_error "Pod creation failed"
    ((ERRORS++))
fi
echo ""

# Test 9: Network Connectivity
print_info "Test 9: Testing pod-to-pod network..."
if kubectl run nettest-1 --image=nginx:alpine --restart=Never &> /dev/null; then
    kubectl wait --for=condition=Ready pod/nettest-1 --timeout=120s &> /dev/null || true
    POD_IP=$(kubectl get pod nettest-1 -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
    if [ -n "$POD_IP" ] && kubectl run nettest-2 --image=busybox:1.28 --rm -i --restart=Never --command -- wget -O- -T 5 "http://$POD_IP" &> /dev/null; then
        print_success "Pod-to-pod networking is working"
    else
        print_error "Pod-to-pod networking failed"
        ((ERRORS++))
    fi
    kubectl delete pod nettest-1 --force --grace-period=0 &> /dev/null || true
else
    print_error "Could not create test pod for network test"
    ((ERRORS++))
fi
echo ""

# Summary
echo "========================================="
echo "Verification Summary"
echo "========================================="
if [ $ERRORS -eq 0 ]; then
    print_success "All tests passed! ✅"
    echo ""
    echo "Your Kubernetes cluster is ready for Phase 1."
    echo ""
    echo "Next step:"
    echo "  cd ../phase1-cluster-istio"
    echo "  ./deploy-phase1.sh"
else
    print_error "Some tests failed ($ERRORS errors)"
    echo ""
    echo "Please review the errors above and fix them before proceeding."
    echo "Common issues:"
    echo "  - Nodes not ready: Check kubelet logs with 'journalctl -u kubelet'"
    echo "  - DNS not working: Check CoreDNS pods with 'kubectl get pods -n kube-system -l k8s-app=kube-dns'"
    echo "  - Network issues: Check Calico pods with 'kubectl get pods -n kube-system -l k8s-app=calico-node'"
    exit 1
fi
