# Phase 1.5: cert-manager for TLS Certificate Management

## Overview

cert-manager v1.15.3 automates the management and issuance of TLS certificates in Kubernetes. This is essential for securing public-facing inference endpoints with HTTPS.

## What's Included

### Certificate Issuers

1. **Let's Encrypt Staging** (`letsencrypt-staging`)
   - For testing only - generates untrusted certificates
   - No rate limits
   - Use this first to verify your setup works

2. **Let's Encrypt Production** (`letsencrypt-prod`)
   - For real HTTPS certificates trusted by browsers
   - **Rate limit**: 50 certificates per domain per week
   - Only use after testing with staging

3. **Self-Signed** (`selfsigned-issuer`)
   - For internal/development use
   - No external dependencies
   - Browsers will show warnings

## Quick Start

### 1. Install cert-manager

```bash
cd /home/ubuntu/ai-stack-production/phase1.5-cert-manager
./deploy-phase1.5.sh
```

### 2. Update Email Address

Before using Let's Encrypt, update your email in:
- `01-letsencrypt-staging.yaml`
- `02-letsencrypt-prod.yaml`

```bash
# Replace admin@example.com with your email
sed -i 's/admin@example.com/your-email@example.com/g' 01-letsencrypt-staging.yaml
sed -i 's/admin@example.com/your-email@example.com/g' 02-letsencrypt-prod.yaml

# Reapply the issuers
kubectl apply -f 01-letsencrypt-staging.yaml
kubectl apply -f 02-letsencrypt-prod.yaml
```

## Prerequisites for Public HTTPS

To get real HTTPS certificates from Let's Encrypt, you need:

1. **Public Domain Name**
   - You must own a domain (e.g., example.com)
   - DNS A record pointing to your cluster's public IP

2. **HTTP-01 Challenge Access**
   - Port 80 must be accessible from the internet
   - Let's Encrypt will connect to verify domain ownership

3. **Istio Gateway Exposed**
   ```bash
   # For single-node (NodePort - development)
   # Access via: http://NODE_IP:30080
   kubectl get nodes -o wide  # Get NODE_IP
   
   # For production (LoadBalancer - requires cloud provider)
   kubectl patch svc istio-ingressgateway -n istio-system -p '{"spec":{"type":"LoadBalancer"}}'
   kubectl get svc istio-ingressgateway -n istio-system  # Get EXTERNAL-IP
   ```

## Usage Examples

### Example 1: Self-Signed Certificate (Development)

```yaml
# Good for testing locally without a domain
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dev-tls
  namespace: istio-system
spec:
  secretName: dev-tls-secret
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  dnsNames:
  - "*.local"
  - "localhost"
```

### Example 2: Let's Encrypt Certificate (Production)

```yaml
# Requires public domain and port 80 access
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: inference-gateway-tls
  namespace: istio-system
spec:
  secretName: inference-gateway-tls
  issuerRef:
    name: letsencrypt-prod  # Start with letsencrypt-staging!
    kind: ClusterIssuer
  dnsNames:
  - api.yourdomain.com
  - models.yourdomain.com
```

### Example 3: Istio Gateway with TLS

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: public-inference-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  # HTTPS (port 443)
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: inference-gateway-tls  # Created by Certificate
    hosts:
    - "api.yourdomain.com"
    - "models.yourdomain.com"
  # HTTP (port 80) - redirect to HTTPS
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
    tls:
      httpsRedirect: true
```

## Testing Your Setup

### 1. Create a Test Certificate (Staging)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-cert-tls
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
  dnsNames:
  - test.yourdomain.com
EOF
```

### 2. Check Certificate Status

```bash
# Watch certificate creation
kubectl get certificate -n default -w

# Check certificate details
kubectl describe certificate test-cert -n default

# Check certificate secret
kubectl get secret test-cert-tls -n default
```

### 3. Troubleshoot Issues

```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Check certificate challenges
kubectl get challenges -A

# Check certificate requests
kubectl get certificaterequests -A

# Describe a failing certificate
kubectl describe certificate test-cert -n default
```

## Common Issues

### Issue: Certificate Stays in "Pending" State

**Cause**: HTTP-01 challenge failing

**Solutions**:
1. Verify port 80 is accessible:
   ```bash
   curl -I http://yourdomain.com/.well-known/acme-challenge/test
   ```

2. Check Istio Gateway allows port 80:
   ```bash
   kubectl get gateway -A
   ```

3. Verify DNS points to correct IP:
   ```bash
   nslookup yourdomain.com
   kubectl get svc istio-ingressgateway -n istio-system
   ```

### Issue: Rate Limit Errors

**Cause**: Too many requests to Let's Encrypt production

**Solutions**:
1. Use `letsencrypt-staging` for testing
2. Wait for rate limit to reset (1 week)
3. Consider using wildcard certificates to reduce number of certs needed

### Issue: "Webhook not ready"

**Cause**: cert-manager webhook not fully initialized

**Solutions**:
```bash
# Wait for webhook
kubectl wait --for=condition=ready pod -l app=webhook -n cert-manager --timeout=120s

# Restart cert-manager if needed
kubectl rollout restart deployment cert-manager -n cert-manager
```

## Integration with KServe

Once cert-manager is installed, you can secure KServe InferenceService endpoints:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: secure-model
  annotations:
    # Use HTTPS
    networking.knative.dev/ingress.class: istio
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: gs://kfserving-examples/models/sklearn/1.0/model
---
# Certificate for the model endpoint
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: secure-model-tls
  namespace: kserve
spec:
  secretName: secure-model-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - secure-model.kserve.yourdomain.com
```

## Production Checklist

- [ ] cert-manager installed and pods running
- [ ] Email updated in issuer configurations
- [ ] DNS records configured for your domain
- [ ] Port 80 accessible from internet for HTTP-01 challenge
- [ ] Port 443 exposed for HTTPS traffic
- [ ] Tested with `letsencrypt-staging` issuer first
- [ ] Switched to `letsencrypt-prod` after successful test
- [ ] Istio Gateway configured with TLS credentials
- [ ] HTTP to HTTPS redirect enabled
- [ ] Certificate renewal working (cert-manager auto-renews at 30 days before expiry)

## Certificate Renewal

cert-manager automatically renews certificates:
- Renewal starts 30 days before expiration
- No manual intervention needed
- Check renewal status:
  ```bash
  kubectl get certificates -A
  kubectl describe certificate <cert-name> -n <namespace>
  ```

## Resources

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)
- [Istio Gateway TLS](https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/)
- [KServe with Custom Domain](https://kserve.github.io/website/latest/modelserving/v1beta1/custom_domain/)

## Uninstall

```bash
# Remove certificate issuers
kubectl delete clusterissuer letsencrypt-staging letsencrypt-prod selfsigned-issuer

# Remove cert-manager
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.yaml
```
