# Istio RBAC Requirements

## Overview

When deploying Istio manually (not using `istioctl` or Helm), you must configure proper RBAC permissions for Istio components to function correctly.

## Issue Fixed

During initial deployment, Istio pods failed to start due to missing RBAC permissions. The errors encountered were:

### 1. Missing Namespace Permissions
```
namespaces is forbidden: User "system:serviceaccount:istio-system:istiod" 
cannot list resource "namespaces" in API group ""
```

### 2. Missing Secret Permissions
```
secrets "istio-ca-secret" is forbidden: User "system:serviceaccount:istio-system:istiod" 
cannot create resource "secrets" in API group ""
```

### 3. Missing Lease Permissions
```
leases.coordination.k8s.io "istio-gateway-deployment-default" is forbidden: 
User "system:serviceaccount:istio-system:istiod" cannot get resource "leases"
```

### 4. Missing EndpointSlices Permissions
```
endpointslices.discovery.k8s.io is forbidden: 
User "system:serviceaccount:istio-system:istiod" cannot list resource "endpointslices"
```

### 5. Missing TokenReview Permissions (Critical)
```
tokenreviews.authentication.k8s.io is forbidden: 
User "system:serviceaccount:istio-system:istiod" cannot create resource "tokenreviews"
```

This last permission is **critical** because Istio uses JWT token validation to authenticate workloads. Without it, the ingress gateway cannot authenticate with istiod, causing authentication failures.

## Solution

The `00-istio-rbac.yaml` file now includes all necessary permissions:

### Core Permissions Required

1. **Service Discovery** - Read access to namespaces, nodes, pods, services, endpoints
2. **Configuration Management** - Full access to secrets and configmaps
3. **Discovery API** - Read access to endpointslices (new in Kubernetes 1.21+)
4. **Leader Election** - Manage leases for leader election
5. **JWT Authentication** - Create tokenreviews for workload authentication

### ClusterRole Configuration

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istiod
rules:
# Service discovery
- apiGroups: [""]
  resources: ["namespaces", "nodes", "pods", "services", "endpoints"]
  verbs: ["get", "list", "watch"]

# Configuration management
- apiGroups: [""]
  resources: ["secrets", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Discovery API (Kubernetes 1.21+)
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]

# Leader election
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]

# JWT token validation (CRITICAL)
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
```

## Deployment Order

The RBAC configuration **must be applied before** deploying Istio components:

1. ✅ Create namespaces (`00-namespaces.yaml`)
2. ✅ Apply RBAC (`00-istio-rbac.yaml`) ← **This step is critical**
3. ✅ Deploy Istio (`01-istio-minimal.yaml`)
4. ✅ Configure mTLS (`02-mtls-strict.yaml`)
5. ✅ Create Gateway (`03-gateway.yaml`)

## Verification

After applying RBAC, verify that Istio pods start successfully:

```bash
# Check istiod deployment
kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s

# Check ingress gateway
kubectl wait --for=condition=ready pod -l app=istio-ingressgateway -n istio-system --timeout=300s

# Verify no authentication errors in istiod logs
kubectl logs -n istio-system -l app=istiod --tail=50 | grep -i error
```

## Why This Matters

- **Without tokenreviews permission**: Ingress gateway cannot authenticate with istiod → CrashLoopBackOff
- **Without endpointslices permission**: Istio cannot discover services properly → service mesh failure
- **Without leases permission**: Leader election fails → multiple istiod instances conflict
- **Without secrets permission**: Cannot manage TLS certificates → mTLS fails

## Comparison with Official Istio Installation

When using `istioctl install` or Helm charts, these RBAC permissions are automatically created. However, our minimal manifest approach requires manual RBAC configuration for:

- **Transparency**: Understand exactly what permissions Istio needs
- **Security**: Only grant necessary permissions
- **Customization**: Easily modify permissions for specific security requirements
- **Learning**: Understand Istio's internal requirements

## References

- [Istio Security Best Practices](https://istio.io/latest/docs/ops/best-practices/security/)
- [Kubernetes RBAC Documentation](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [TokenReview API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/)

## Troubleshooting

If Istio pods are not starting:

1. Check RBAC permissions are applied:
   ```bash
   kubectl get clusterrole istiod
   kubectl get clusterrolebinding istiod
   ```

2. Check pod logs for permission errors:
   ```bash
   kubectl logs -n istio-system -l app=istiod --tail=100
   kubectl logs -n istio-system -l app=istio-ingressgateway --tail=100
   ```

3. Look for specific forbidden errors:
   - `namespaces is forbidden` → Missing namespace list permission
   - `secrets is forbidden` → Missing secret create/update permission
   - `leases is forbidden` → Missing lease permission
   - `endpointslices is forbidden` → Missing endpointslices permission
   - `tokenreviews is forbidden` → Missing JWT validation permission

4. Re-apply RBAC and restart pods:
   ```bash
   kubectl apply -f 00-istio-rbac.yaml
   kubectl delete pod -n istio-system -l app=istiod
   kubectl delete pod -n istio-system -l app=istio-ingressgateway
   ```
