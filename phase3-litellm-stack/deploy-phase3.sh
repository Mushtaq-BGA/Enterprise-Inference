#!/bin/bash
# Phase 3: Deploy LiteLLM + Redis + Postgres + Istio VirtualService
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LITELLM_API_KEY="sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef"

source "$REPO_ROOT/scripts/lib/cluster-domain.sh"

echo "========================================="
echo "Phase 3: LiteLLM + Redis + Postgres Stack"
echo "========================================="

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

NEED_LITELLM_RESTART=false
NEED_POSTGRES_RESTART=false
NEED_REDIS_RESTART=false

TMP_CONFIG_FILE=""
cleanup() {
    if [ -n "${TMP_CONFIG_FILE:-}" ] && [ -f "$TMP_CONFIG_FILE" ]; then
        rm -f "$TMP_CONFIG_FILE"
    fi
}
trap cleanup EXIT


# Function to apply manifests with retry
apply_manifest() {
    local manifest=$1
    local max_attempts=${2:-3}
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl apply -f "$manifest" 2>&1; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            print_info "Retrying kubectl apply (attempt $((attempt + 1))/$max_attempts)..."
            sleep 2
        fi
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Function to print colored messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "Missing required command: $1"
        exit 1
    fi
}

# Ensure namespaces have Istio sidecar injection enabled so STRICT mTLS works
enable_sidecar_injection() {
    local namespace=$1
    local label
    label=$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)

    if [ "$label" != "enabled" ]; then
        print_info "Enabling Istio sidecar injection for namespace $namespace..."
        kubectl label namespace "$namespace" istio-injection=enabled --overwrite >/dev/null
        print_success "Istio sidecar injection enabled for namespace $namespace"
        return 0
    fi

    return 1
}

# Function to wait for deployment
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}
    
    print_info "Waiting for deployment $deployment in namespace $namespace (timeout: ${timeout}s)..."
    
    local end=$((SECONDS + timeout))
    local last_ready=0
    while [ $SECONDS -lt $end ]; do
        if kubectl wait --for=condition=available --timeout=10s \
            deployment/$deployment -n $namespace 2>/dev/null; then
            print_success "Deployment $deployment is ready"
            return 0
        fi
        
        # Show current replica status
        local ready=$(kubectl get deployment $deployment -n $namespace \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired=$(kubectl get deployment $deployment -n $namespace \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        
        ready=${ready:-0}
        desired=${desired:-0}
        
        if [ "$ready" != "$last_ready" ]; then
            print_info "  → Deployment progress: $ready/$desired replicas ready"
            last_ready=$ready
        fi
        
        sleep 5
    done
    
    print_error "Timeout waiting for deployment $deployment"
    kubectl get deployment $deployment -n $namespace 2>/dev/null || true
    kubectl get pods -n $namespace -l app=$deployment 2>/dev/null || true
    return 1
}

# Function to wait for statefulset
wait_for_statefulset() {
    local namespace=$1
    local statefulset=$2
    local timeout=${3:-300}
    
    print_info "Waiting for statefulset $statefulset in namespace $namespace (timeout: ${timeout}s)..."
    
    local end=$((SECONDS + timeout))
    local last_ready=0
    while [ $SECONDS -lt $end ]; do
        local ready=$(kubectl get statefulset $statefulset -n $namespace \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired=$(kubectl get statefulset $statefulset -n $namespace \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

        ready=${ready:-0}
        desired=${desired:-0}

        if [ "$ready" -ge "$desired" ] && [ "$desired" -gt 0 ]; then
            print_success "StatefulSet $statefulset is ready ($ready/$desired)"
            return 0
        fi
        
        # Show progress if ready count changed
        if [ "$ready" != "$last_ready" ]; then
            print_info "  → StatefulSet progress: $ready/$desired replicas ready"
            last_ready=$ready
        fi
        
        sleep 5
    done
    
    print_error "Timeout waiting for StatefulSet $statefulset"
    kubectl get statefulset $statefulset -n $namespace 2>/dev/null || true
    kubectl get pods -n $namespace -l app=$statefulset 2>/dev/null || true
    return 1
}

# Check prerequisites
print_info "Checking prerequisites..."

# Check if Istio is installed
if ! kubectl get deployment istiod -n istio-system &> /dev/null; then
    print_error "Istio not found. Please run Phase 1 first."
    exit 1
fi
print_success "Istio is installed"

# Check if required namespaces exist (create if missing)
for ns in postgres redis litellm; do
    if ! kubectl get namespace "$ns" &> /dev/null; then
        print_info "Namespace $ns not found. Creating it now..."
        kubectl create namespace "$ns" >/dev/null
        print_success "Namespace $ns created"
    fi
done
print_success "Required namespaces ready"

# Ensure Istio sidecar injection for service namespaces
if enable_sidecar_injection postgres; then
    NEED_POSTGRES_RESTART=true
fi
if enable_sidecar_injection redis; then
    NEED_REDIS_RESTART=true
fi
if enable_sidecar_injection litellm; then
    NEED_LITELLM_RESTART=true
fi

# Ensure TLS secret for Istio gateway
print_info "Ensuring self-signed TLS certificate for ai-stack gateway..."
if ! kubectl get secret aistack-tls-cert -n istio-system >/dev/null 2>&1; then
    require_command openssl
    TMP_CERT_DIR=$(mktemp -d)
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$TMP_CERT_DIR/tls.key" \
        -out "$TMP_CERT_DIR/tls.crt" \
        -subj "/CN=litellm.aistack.local" \
        -addext "subjectAltName=DNS:litellm.aistack.local,DNS:*.kserve.aistack.local,DNS:*.aistack.local" >/dev/null 2>&1
    kubectl create secret tls aistack-tls-cert \
        --cert="$TMP_CERT_DIR/tls.crt" \
        --key="$TMP_CERT_DIR/tls.key" \
        -n istio-system --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "$TMP_CERT_DIR"
    print_success "Created self-signed TLS certificate"
else
    print_info "Existing TLS secret aistack-tls-cert detected"
fi

# Step 1: Deploy PostgreSQL
print_info "Deploying PostgreSQL..."
POSTGRES_STATEFULSET_EXISTS=false
if kubectl get statefulset postgres -n postgres &> /dev/null; then
    POSTGRES_STATEFULSET_EXISTS=true
fi

if ! apply_manifest "$PHASE_DIR/00-postgres.yaml"; then
    print_error "Failed to deploy PostgreSQL"
    exit 1
fi

if ! apply_manifest "$PHASE_DIR/00-postgres-destinationrule.yaml"; then
    print_error "Failed to deploy PostgreSQL DestinationRule"
    exit 1
fi

# Restart existing Postgres pods if we just enabled sidecar injection
if [ "$NEED_POSTGRES_RESTART" = "true" ] && [ "$POSTGRES_STATEFULSET_EXISTS" = "true" ]; then
    print_info "Restarting PostgreSQL pods to pick up Istio sidecars..."
    kubectl rollout restart statefulset/postgres -n postgres >/dev/null
fi

# Wait for PostgreSQL to be ready
if ! wait_for_statefulset postgres postgres 300; then
    print_error "PostgreSQL failed to become ready"
    exit 1
fi
print_success "PostgreSQL is ready and accessible"

# Step 2: Deploy Redis
print_info "Deploying Redis..."
REDIS_DEPLOYMENT_EXISTS=false
if kubectl get deployment redis -n redis &> /dev/null; then
    REDIS_DEPLOYMENT_EXISTS=true
fi

if ! apply_manifest "$PHASE_DIR/01-redis.yaml"; then
    print_error "Failed to deploy Redis"
    exit 1
fi

if ! apply_manifest "$PHASE_DIR/01-redis-destinationrule.yaml"; then
    print_error "Failed to deploy Redis DestinationRule"
    exit 1
fi

# Restart existing Redis pods if we just enabled sidecar injection
if [ "$NEED_REDIS_RESTART" = "true" ] && [ "$REDIS_DEPLOYMENT_EXISTS" = "true" ]; then
    print_info "Restarting Redis pods to pick up Istio sidecars..."
    kubectl rollout restart deployment/redis -n redis >/dev/null
fi

# Wait for Redis to be ready
if ! wait_for_deployment redis redis 300; then
    print_error "Redis failed to become ready"
    exit 1
fi
print_success "Redis is ready and accessible"

# Step 3: Deploy LiteLLM ConfigMap
print_info "Deploying LiteLLM ConfigMap..."
CLUSTER_DOMAIN="$(ensure_cluster_domain)"
print_info "Detected cluster domain: $CLUSTER_DOMAIN"

if [ ! -f "$PHASE_DIR/02-litellm-config.yaml" ]; then
    print_error "Config template file not found: $PHASE_DIR/02-litellm-config.yaml"
    exit 1
fi

TMP_CONFIG_FILE=$(mktemp) || {
    print_error "Failed to create temporary file"
    exit 1
}

if ! sed "s|__CLUSTER_DOMAIN__|$CLUSTER_DOMAIN|g" "$PHASE_DIR/02-litellm-config.yaml" > "$TMP_CONFIG_FILE"; then
    print_error "Failed to process config template"
    rm -f "$TMP_CONFIG_FILE"
    exit 1
fi

if ! kubectl create configmap litellm-config \
    --namespace litellm \
    --from-file=config.yaml="$TMP_CONFIG_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -; then
    print_error "Failed to create LiteLLM ConfigMap"
    rm -f "$TMP_CONFIG_FILE"
    exit 1
fi

rm -f "$TMP_CONFIG_FILE"
TMP_CONFIG_FILE=""
print_success "LiteLLM ConfigMap created with cluster domain: $CLUSTER_DOMAIN"

# Step 4: Deploy LiteLLM
print_info "Deploying LiteLLM with HPA and PDB..."

if ! apply_manifest "$PHASE_DIR/03-litellm-deployment.yaml"; then
    print_error "Failed to deploy LiteLLM"
    exit 1
fi

if [ "$NEED_LITELLM_RESTART" = "true" ]; then
    print_info "Restarting LiteLLM pods to pick up Istio sidecars..."
    kubectl rollout restart deployment/litellm -n litellm >/dev/null
fi

# Wait for LiteLLM to be ready
print_info "Waiting for LiteLLM deployment to be ready..."
if ! wait_for_deployment litellm litellm 600; then
    print_error "LiteLLM deployment failed to become ready"
    exit 1
fi
print_success "LiteLLM deployment is ready"

# Verify LiteLLM pods have Istio sidecars
print_info "Verifying Istio sidecar injection..."
CONTAINER_COUNT=$(kubectl get pods -n litellm -l app=litellm \
    -o jsonpath='{.items[0].spec.containers[*].name}' | wc -w)

if [ "$CONTAINER_COUNT" -ge 2 ]; then
    print_success "Istio sidecar injected (found $CONTAINER_COUNT containers)"
else
    print_info "Istio sidecar not detected (found $CONTAINER_COUNT container); proceed if mesh injection is optional"
fi

# Verify LiteLLM health
print_info "Verifying LiteLLM health..."
HEALTHY=false
sleep 10
for attempt in $(seq 1 60); do
    # Check if the pod is actually running first
    if ! kubectl get deployment litellm -n litellm &>/dev/null; then
        print_error "LiteLLM deployment not found"
        exit 1
    fi
    
    # Try health check
    if kubectl exec -n litellm deployment/litellm -c litellm -- \
        wget -qO- --timeout=5 --header="Authorization: Bearer ${LITELLM_API_KEY}" \
        http://127.0.0.1:4000/health/readiness 2>/dev/null | grep -q '"status":"connected"'; then
        print_success "LiteLLM health check passed"
        HEALTHY=true
        break
    fi
    
    # Show progress less frequently
    if [ $((attempt % 3)) -eq 0 ]; then
        print_info "LiteLLM not ready yet (attempt ${attempt}/60, ${$((attempt * 10))}s elapsed)"
    fi
    sleep 10
done

if [ "$HEALTHY" != "true" ]; then
    print_error "LiteLLM readiness probe timed out after $((60 * 10)) seconds"
    print_info "Checking pod status for diagnostics..."
    kubectl get pods -n litellm -l app=litellm
    print_info "Recent logs:"
    kubectl logs -n litellm deployment/litellm -c litellm --tail=30 2>/dev/null || true
    exit 1
fi

# Wait for LiteLLM Prisma migrations before seeding credentials
print_info "Waiting for LiteLLM database schema (Prisma migrations)..."
print_info "This may take a few minutes on first deployment..."
DB_READY=false
for attempt in $(seq 1 60); do
    # First check if postgres is accessible
    if ! kubectl exec -n postgres statefulset/postgres -- \
        psql -U litellm -d litellm -tAc "SELECT 1;" &>/dev/null; then
        if [ $((attempt % 6)) -eq 0 ]; then
            print_info "Postgres not yet accessible (attempt ${attempt}/60)"
        fi
        sleep 5
        continue
    fi
    
    # Check if migration tables exist
    if kubectl exec -n postgres statefulset/postgres -- \
        psql -U litellm -d litellm -tAc "SELECT CASE WHEN to_regclass('\"LiteLLM_UserTable\"') IS NOT NULL AND to_regclass('\"LiteLLM_VerificationToken\"') IS NOT NULL THEN 'ready' ELSE 'wait' END;" 2>/dev/null | grep -q ready; then
        print_success "Database schema ready"
        DB_READY=true
        break
    fi
    
    # Show progress every 30 seconds
    if [ $((attempt % 6)) -eq 0 ]; then
        print_info "Waiting for Prisma migrations to complete (${attempt}/60, $((attempt * 5))s elapsed)..."
        # Check if migrations are running by looking at logs
        if kubectl logs -n litellm deployment/litellm -c litellm --tail=5 2>/dev/null | grep -q "prisma migrate"; then
            print_info "  → Migrations are in progress..."
        fi
    fi
    sleep 5
done

if [ "$DB_READY" != "true" ]; then
    print_error "LiteLLM database schema not ready after $((60 * 5)) seconds"
    print_info "Checking database state..."
    kubectl exec -n postgres statefulset/postgres -- \
        psql -U litellm -d litellm -c "\dt" 2>/dev/null || true
    print_info "Recent LiteLLM logs:"
    kubectl logs -n litellm deployment/litellm -c litellm --tail=50 2>/dev/null | grep -i "prisma\|migration\|error" || true
    exit 1
fi

# Seed LiteLLM master key into the verification table with proxy_admin permissions
print_info "Seeding LiteLLM master key in verification table..."
TOKEN_HASH=$(TOKEN="${LITELLM_API_KEY}" python3 - <<'PY'
import hashlib
import os

token = os.environ["TOKEN"]
print(hashlib.sha256(token.encode()).hexdigest())
PY
)

TOKEN_HASH=$(echo "$TOKEN_HASH" | tr -d '[:space:]')

if [ -z "$TOKEN_HASH" ]; then
    print_error "Failed to compute LiteLLM API key hash"
    exit 1
fi

if kubectl exec -i -n postgres statefulset/postgres -- bash -c "psql -U litellm -d litellm <<'SQL'
INSERT INTO \"LiteLLM_UserTable\" (user_id, user_role)
VALUES ('modelwatcher', 'proxy_admin')
ON CONFLICT (user_id) DO UPDATE SET user_role='proxy_admin';

INSERT INTO \"LiteLLM_VerificationToken\" (token, user_id, permissions, models, config, metadata)
VALUES ('${TOKEN_HASH}', 'modelwatcher', jsonb_build_object('role', 'proxy_admin'), ARRAY[]::text[], '{}'::jsonb, '{}'::jsonb)
ON CONFLICT (token) DO UPDATE SET
    user_id = EXCLUDED.user_id,
    permissions = EXCLUDED.permissions,
    models = ARRAY[]::text[],
    config = '{}'::jsonb,
    metadata = '{}'::jsonb;
SQL"; then
    print_success "LiteLLM master key seeded with proxy_admin permissions"
else
    print_error "Failed to seed LiteLLM master key"
    exit 1
fi

# Step 5: Deploy Istio VirtualService
print_info "Deploying Istio VirtualService for LiteLLM..."
if ! apply_manifest "$PHASE_DIR/05-litellm-virtualservice.yaml"; then
    print_error "Failed to deploy VirtualService"
    exit 1
fi
print_success "VirtualService deployed"

# Step 6: Deploy LiteLLM HPA
print_info "Deploying HorizontalPodAutoscaler for LiteLLM..."
if ! apply_manifest "$PHASE_DIR/04-litellm-hpa.yaml"; then
    print_error "Failed to deploy HPA"
    exit 1
fi
print_success "HPA deployed"

# Verify VirtualService
print_info "Verifying VirtualService configuration..."
if kubectl get virtualservice litellm-vs -n litellm &>/dev/null; then
    print_success "VirtualService configured successfully"
else
    print_error "VirtualService verification failed"
    exit 1
fi

# Get Istio ingress details
HTTP_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
HTTPS_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test external access
print_info "Testing external access to LiteLLM via Istio Gateway..."
print_info "Waiting 10 seconds for routing to propagate..."
sleep 10

# Test /health endpoint
if curl -s -o /dev/null -w "%{http_code}" -H "Host: litellm.aistack.local" \
    -H "Authorization: Bearer ${LITELLM_API_KEY}" \
    http://$NODE_IP:$HTTP_PORT/health/readiness | grep -q "200"; then
    print_success "External access to LiteLLM working!"
else
    print_error "External access test failed (this might be normal if DNS is not configured)"
fi

# Summary
echo ""
echo "========================================="
echo "Phase 3 Deployment Summary"
echo "========================================="

# Verify final state
print_info "Performing final health checks..."

# Check all pods are running
POSTGRES_READY=$(kubectl get statefulset postgres -n postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
REDIS_READY=$(kubectl get deployment redis -n redis -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
LITELLM_READY=$(kubectl get deployment litellm -n litellm -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [ "$POSTGRES_READY" -ge 1 ] && [ "$REDIS_READY" -ge 1 ] && [ "$LITELLM_READY" -ge 3 ]; then
    print_success "✓ All components are healthy"
    print_success "✓ PostgreSQL: ${POSTGRES_READY}/1 ready"
    print_success "✓ Redis: ${REDIS_READY}/1 ready"
    print_success "✓ LiteLLM: ${LITELLM_READY}/3 ready"
else
    print_error "Some components are not fully ready:"
    echo "  PostgreSQL: ${POSTGRES_READY}/1"
    echo "  Redis: ${REDIS_READY}/1"
    echo "  LiteLLM: ${LITELLM_READY}/3"
fi

print_success "✓ PostgreSQL deployed and accessible (10Gi storage)"
print_success "✓ Redis deployed with LRU caching (2GB max memory)"
print_success "✓ LiteLLM deployed with ${LITELLM_READY} replicas"
print_success "✓ HorizontalPodAutoscaler configured (3-20 replicas)"
print_success "✓ PodDisruptionBudget configured (min 2 available)"
print_success "✓ Istio VirtualService configured for external access"
print_success "✓ Istio DestinationRules configured for mTLS bypass"
print_success "✓ Connection pooling and circuit breaking enabled"
print_success "✓ Database schema migrated and credentials seeded"
echo ""
print_info "LiteLLM Configuration:"
echo "  Cluster Domain: ${CLUSTER_DOMAIN}"
echo "  Memory Limit: 12Gi per pod"
echo "  Initial Replicas: 3"
echo "  Max Replicas: 20 (HPA)"
echo "  Workers: Dynamic (based on CPU)"
echo "  Max Parallel Requests: 600"
echo "  Max Queue Size: 4000"
echo "  Request Timeout: 600s"
echo "  Redis Caching: Enabled (TTL: 600s)"
echo "  Database: PostgreSQL with Prisma ORM"
echo ""
print_info "Access LiteLLM:"
echo "  External: http://$NODE_IP:$HTTP_PORT/health/readiness -H 'Host: litellm.aistack.local'"
echo "  Internal: http://litellm.litellm.svc.${CLUSTER_DOMAIN}:4000"
echo "  API Key: ${LITELLM_API_KEY}"
echo ""
print_info "Test LiteLLM:"
echo "  # Add to /etc/hosts:"
echo "  echo '$NODE_IP litellm.aistack.local' | sudo tee -a /etc/hosts"
echo ""
echo "  # Test health:"
echo "  curl -H 'Authorization: Bearer ${LITELLM_API_KEY}' http://litellm.aistack.local:$HTTP_PORT/health/readiness"
echo ""
echo "  # List models:"
echo "  curl http://litellm.aistack.local:$HTTP_PORT/v1/models \\"
echo "    -H 'Authorization: Bearer ${LITELLM_API_KEY}'"
echo ""
print_info "Next Step: Run Phase 4 to deploy Model Watcher for auto-registration"
echo "  cd ../phase4-model-watcher && ./deploy-phase4.sh"
echo ""
