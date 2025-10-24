# Local HTTPS Setup for AI Stack

This guide explains how to set up and test HTTPS connectivity for the AI Stack on any fresh machine.

## Quick Start

Run the automated setup script:

```bash
./scripts/setup-local-https.sh
```

The script will automatically:
1. ✅ Check Istio gateway deployment
2. ✅ Create self-signed TLS certificate (if needed)
3. ✅ Verify gateway HTTPS configuration
4. ✅ Update `/etc/hosts` with the correct hostname
5. ✅ Test HTTPS connectivity with 3 comprehensive tests
6. ✅ Display access information and example commands

## What the Script Does

### 1. Certificate Management
- Checks if `aistack-tls-cert` secret exists in `istio-system` namespace
- Creates a self-signed certificate for `*.aistack.local` if missing
- Certificate is valid for 365 days and covers:
  - `*.aistack.local`
  - `aistack.local`
  - `*.kserve.aistack.local`
  - `litellm.aistack.local`

### 2. Gateway Configuration Verification
- Verifies `ai-stack-gateway` has HTTPS listener on port 443
- Checks TLS mode is set to `SIMPLE` (TLS termination)
- Confirms gateway references the correct certificate

### 3. Local DNS Setup
- Adds/updates entry in `/etc/hosts`: `<NODE_IP> litellm.aistack.local`
- Automatically detects the node's internal IP
- Required for proper SNI (Server Name Indication) during TLS handshake

### 4. Connectivity Tests

**Test 1: Health Check**
```bash
curl -k https://litellm.aistack.local:32443/health/readiness
```
Expected: HTTP 200 with `{"status":"healthy",...}`

**Test 2: Models API**
```bash
curl -k https://litellm.aistack.local:32443/v1/models \
  -H "Authorization: Bearer <API_KEY>"
```
Expected: HTTP 200 with list of available models

**Test 3: TLS Certificate Details**
```bash
openssl s_client -connect litellm.aistack.local:32443 \
  -servername litellm.aistack.local
```
Expected: Certificate details showing subject and validity

## Usage Examples

After running the script, you can access the API via HTTPS:

### Health Check
```bash
curl -k https://litellm.aistack.local:32443/health/readiness
```

### List Available Models
```bash
curl -k https://litellm.aistack.local:32443/v1/models \
  -H "Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef"
```

### Chat Completion
```bash
curl -k https://litellm.aistack.local:32443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef" \
  -d '{
    "model": "qwen3-4b-int4-ov",
    "messages": [
      {"role": "user", "content": "Hello! How are you?"}
    ]
  }'
```

### Streaming Response
```bash
curl -k https://litellm.aistack.local:32443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-52e2c3a5f98b4d5ca9d2e1327d6b41ef" \
  -d '{
    "model": "qwen3-4b-int4-ov",
    "messages": [{"role": "user", "content": "Tell me a joke"}],
    "stream": true
  }'
```

## Remote Access

To access the HTTPS endpoint from a different machine:

1. **Get the node's public IP** (if available):
   ```bash
   curl -s http://checkip.amazonaws.com
   ```

2. **Add to client's `/etc/hosts`**:
   ```bash
   # On the client machine
   echo "<PUBLIC_IP> litellm.aistack.local" | sudo tee -a /etc/hosts
   ```

3. **Access via HTTPS**:
   ```bash
   curl -k https://litellm.aistack.local:32443/health/readiness
   ```

## Browser Access

For browser access (dashboard):

1. Navigate to: `https://litellm.aistack.local:32443`

2. You'll see a security warning because the certificate is self-signed

3. Accept the security exception:
   - **Chrome/Edge**: Click "Advanced" → "Proceed to litellm.aistack.local (unsafe)"
   - **Firefox**: Click "Advanced" → "Accept the Risk and Continue"
   - **Safari**: Click "Show Details" → "visit this website"

4. The dashboard should load normally

## Troubleshooting

### Issue: `curl: (35) Connection reset by peer`

**Cause**: Using IP address instead of hostname in URL

**Solution**: Always use the hostname in the URL, not just in the Host header:
```bash
# ❌ Wrong
curl -k https://10.0.15.238:32443/health -H "Host: litellm.aistack.local"

# ✅ Correct
curl -k https://litellm.aistack.local:32443/health
```

### Issue: `curl: (6) Could not resolve host`

**Cause**: Missing `/etc/hosts` entry

**Solution**: Run the setup script again or manually add:
```bash
echo "<NODE_IP> litellm.aistack.local" | sudo tee -a /etc/hosts
```

### Issue: Certificate verification failed

**Cause**: Self-signed certificate not trusted

**Solution**: Use `-k` flag with curl to ignore certificate verification:
```bash
curl -k https://litellm.aistack.local:32443/health/readiness
```

### Issue: Connection timeout

**Possible causes**:
1. Firewall blocking port 32443
2. Istio gateway not running
3. Wrong IP address in `/etc/hosts`

**Solutions**:
```bash
# Check gateway is running
kubectl get pods -n istio-system -l app=istio-ingressgateway

# Check HTTPS port
kubectl get svc istio-ingressgateway -n istio-system

# Check firewall (if applicable)
sudo ufw status
```

## Technical Details

### Why Hostname is Required

The script uses hostname-based access (`litellm.aistack.local`) instead of IP-based for these reasons:

1. **SNI (Server Name Indication)**: Modern TLS requires the client to send the hostname during the TLS handshake
2. **Istio Gateway Routing**: The gateway uses SNI to route traffic to the correct virtual service
3. **Certificate Validation**: The certificate is issued for `*.aistack.local`, not for IP addresses

### Certificate Details

The self-signed certificate created by the script:
- **Subject**: `O=AI Stack Inc., CN=*.aistack.local`
- **Issuer**: `O=AI Stack Inc., CN=*.aistack.local` (self-signed)
- **Validity**: 365 days from creation
- **Key Type**: RSA 2048-bit
- **SANs**: `*.aistack.local`, `aistack.local`, `*.kserve.aistack.local`, `litellm.aistack.local`

### Ports

- **HTTP**: Port 32080 (NodePort for port 80)
- **HTTPS**: Port 32443 (NodePort for port 443)

Both ports are exposed via Istio ingress gateway service.

## Production Considerations

For production deployments, consider:

1. **Real TLS Certificates**: Use Let's Encrypt or other CA instead of self-signed
   - Requires a real domain name
   - Can use cert-manager with ACME (already deployed in Phase 1.5)

2. **Load Balancer**: Use cloud provider's load balancer instead of NodePort
   - Easier to manage
   - Standard ports (80/443)
   - Better performance

3. **DNS**: Set up proper DNS records instead of `/etc/hosts`
   - More scalable
   - Works across multiple clients
   - Professional appearance

4. **Firewall**: Configure security groups/firewall rules properly
   - Only allow necessary ports
   - Restrict access by IP if needed
   - Use VPN for internal services

## Integration with CI/CD

To use this script in automated deployments:

```bash
#!/bin/bash
# deploy.sh

# Deploy the AI stack
./phase0-kubernetes-cluster/deploy-single-node.sh
./phase1-cluster-istio/deploy-phase1.sh
./phase1.5-cert-manager/deploy-phase1.5.sh
./phase2-knative-kserve/deploy-phase2.sh
./phase3-litellm-stack/deploy-phase3.sh
./phase4-model-watcher/deploy-phase4.sh

# Setup and test HTTPS
./scripts/setup-local-https.sh

# If successful, continue with other tasks
if [ $? -eq 0 ]; then
    echo "Deployment complete and HTTPS verified!"
else
    echo "HTTPS setup failed!"
    exit 1
fi
```

## See Also

- [Phase 1 Istio Deployment](../phase1-cluster-istio/README.md)
- [Istio Security Verification](../docs/ISTIO_SECURITY_VERIFICATION.md)
- [Cert-Manager Setup](../phase1.5-cert-manager/README.md)
- [LiteLLM Configuration](../phase3-litellm-stack/README.md)
