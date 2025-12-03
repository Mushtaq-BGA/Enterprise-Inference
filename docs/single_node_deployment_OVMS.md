# Single Node Deployment Guide

This guide provides step-by-step instructions to deploy Intel® AI for Enterprise Inference on a single node.

## Prerequisites
Before running the automation, complete all [prerequisites](./prerequisites.md).

## Deployment

### Step 1: Configure the Automation config file
Clone the Enterprise Inference repo, then copy the single node preset inference config file to the working directory:

### Step 1: Modify the hosts file
Since we are testing locally, we need to map a fake domain (`api.example.com`) to `localhost` in the `/etc/hosts` file.

Run the following command to edit the hosts file:
```
sudo nano /etc/hosts
```
Add this line at the end:
```
127.0.0.1 api.example.com
```
Save and exit (`CTRL+X`, then `Y` and `Enter`).

### Step 2: Generate a self-signed SSL certificate
Run the following command to create a self-signed SSL certificate that covers api.example.com and trace-api.example.com:
```bash
mkdir -p ~/certs && cd ~/certs && \
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=api.example.com" \
  -addext "subjectAltName = DNS:api.example.com, DNS:trace-api.example.com"
```
Note: the -addext option requires OpenSSL >= 1.1.1.

Files produced:
- cert.pem — the self-signed certificate (contains SANs)
- key.pem — the private key

Important DNS step:
Please add trace-api.example.com to DNS and point it to the node where Ingress controller is deployed.

### Step 3: Configure the Automation config file
Move the single node preset inference config file to the runnig directory

```
cd ~
git clone https://github.com/opea-project/Enterprise-Inference.git
cd Enterprise-Inference
cp -f docs/examples/single-node/inference-config.cfg core/inventory/inference-config.cfg
```

Modify `inference-config.cfg` and set deploy_llm_models variable to off as shown below 
*deploy_llm_models=off*
 Ensure the `cluster_url` field is set to the DNS used, and the paths to the certificate and key files are valid. The keycloak fields and deployment options can be left unchanged. For systems behind a proxy, refer to the [proxy guide](./running-behind-proxy.md).

### Step 2: Update `hosts.yaml` File
Copy the single node preset hosts config file to the working directory:

```bash
cp -f docs/examples/single-node/hosts.yaml core/inventory/hosts.yaml
```

> **Note** The `ansible_user` field is set to *ubuntu* by default. Change it to the actual username used. 

Export the Hugging Face token as an environment variable by replacing "Your_Hugging_Face_Token_ID" with actual Hugging Face Token. Alternatively, set `hugging-face-token` to the token value inside `inference-config.cfg`.
```bash
export HUGGINGFACE_TOKEN=<<Your_Hugging_Face_Token_ID>>
```
### Step 3: Navigate to the Helm Chart Directory

```bash
cd Enterprise-Inference/core/helm-charts/ovms/
```

### Step 4: Edit the `values.yaml` File

Open the `values.yaml` file and configure the following parameters:

#### OIDC Configuration

Configure OpenID Connect authentication with your Keycloak instance:

```yaml
oidc:
  enabled: true
  realm: master
  clientId: "your-client-id"                    # Update this using below steps mentioned in NOTE section
  clientSecret: "your-client-secret"            # Update this using below steps mentioned in NOTE section
  discovery: "http://keycloak.default.svc.cluster.local/realms/master/.well-known/openid-configuration"
  introspectionEndpoint: "http://keycloak.default.svc.cluster.local/realms/master/protocol/openid-connect/token/introspect"

NOTE: you can get clientId and clientSecret as shown below

export KEYCLOAK_CLIENT_ID=my-client-id # The client ID to be created in Keycloak as menitoned in your inference-config.cfg file in step 3
export KEYCLOAK_CLIENT_SECRET=$(bash "${SCRIPT_DIR}/keycloak-fetch-client-secret.sh" ${KEYCLOAK_URL} ${KEYCLOAK_ADMIN_USERNAME} ${KEYCLOAK_PASSWORD} ${KEYCLOAK_CLIENT_ID} | awk -F': ' '/Client secret:/ {print $2}')

echo $KEYCLOAK_CLIENT_ID         # this will print your keycloak client ID that can be used in above OIDC configuration
echo $KEYCLOAK_CLIENT_SECRET     # this will print your keycloak client secret that can be used in above OIDC configuration

#### Host Configuration

Set your domain/hostname:

```yaml
apisixRoute:
  enabled: true
  namespace: default
  name: ""
  host: "api.example.com"  # Update this

ingress:
  enabled: true
  className: nginx
  namespace: auth-apisix
  host: "api.example.com"  # Update this (same as above)
  secretname: ""  # Update this (your TLS secret name)
```
---

## Deployment

Below are the pre-tested models and the respective Helm commands to deploy

For Deploying `Qwen3-4B-int4-ov` model:
```bash
helm install qwen3-4b . --set modelSource="OpenVINO/Qwen3-4B-int4-ov" --set modelName="qwen3-4b"
```
For Deploying `Phi-3.5-mini-instruct-int4-cw-ov` model:
```bash
helm install phi-3-5-mini . --set modelSource="OpenVINO/Phi-3.5-mini-instruct-int4-cw-ov" --set modelName="phi-3-5-mini"
```
For Deploying `Mistral-7B-Instruct-v0.3-int4-cw-ov` model:
```bash
helm install mistral-7b . --set modelSource="OpenVINO/Mistral-7B-Instruct-v0.3-int4-cw-ov" --set modelName="mistral-7b"
```

**Note:** Model download may take 5-10 minutes depending on model size and network speed.

### Accessing the deployed models and testing

First, obtain an access token:

```bash
export CLIENTID=$KEYCLOAK_CLIENT_ID 
export CLIENT_SECRET=$KEYCLOAK_CLIENT_SECRET
export TOKEN_URL=https://${BASE_URL}/token
export TOKEN=$(curl -k -X POST ${TOKEN_URL} -H 'Content-Type: application/x-www-form-urlencoded' -d "grant_type=client_credentials&client_id=${CLIENTID}&client_secret=${CLIENT_SECRET}" | jq -r .access_token)

echo "Access Token: $TOKEN"
```

### Test via External URL (with Authentication)

```bash
# Test chat completions endpoint
For Inferencing with Qwen3-4B-int4-ov:
curl -k ${BASE_URL}/qwen3-4b-ovms/v1/completions -X POST -d '{"messages": [{"role": "system","content": "You are helpful assistant"},{"role": "user","content": "what is photosynthesis"}],"model": "qwen3-4b","max_tokens": 32,"temperature": 0.4}' -H 'Content-Type: application/json' -sS -H "Authorization: Bearer $TOKEN"

For Inferencing with Phi-3.5-mini-instruct-int4-cw-ov:
curl -k ${BASE_URL}/phi-3-5-mini-ovms/v3/chat/completions -X POST -d '{"messages": [{"role": "system","content": "You are helpful assistant"},{"role": "user","content": "what is api"}],"model": "phi-3-5-mini","max_tokens": 32,"temperature": 0.4}' -H 'Content-Type: application/json' -sS -H "Authorization: Bearer $TOKEN"

For Inferencing with Mistral-7B-Instruct-v0.3-int4-cw-ov:
curl -k ${BASE_URL}/mistral-7b-ovms/v3/chat/completions -X POST -d '{"messages": [{"role": "system","content": "You are helpful assistant"},{"role": "user","content": "what is photosynthesis"}],"model": "mistral-7b","max_tokens": 32,"temperature": 0.4}' -H 'Content-Type: application/json' -sS -H "Authorization: Bearer $TOKEN"

```
---
## Undeployment

### Complete Removal

To completely remove the deployment:

```bash
# Uninstall the Helm release
helm uninstall qwen3-ovms

# Verify removal
helm list
kubectl get pods -l app=ovms-model-server
kubectl get svc -l app=ovms-model-server
kubectl get apisixroute -n default
kubectl get ingress -n auth-apisix
```

## Advanced Configuration

### Deploy Multiple Models

To deploy multiple models, use different release names:

```bash
# Deploy Qwen3-8B
helm install qwen3-8b . \
  --set modelSource="OpenVINO/Qwen3-8B-int4-ov" \
  --set modelName="qwen3-8b" \
  --set apisixRoute.host="qwen-inference.example.com"

# Deploy Qwen3-4B
helm install qwen3-4b . \
  --set modelSource="OpenVINO/Qwen3-4B-int4-ov" \
  --set modelName="qwen3-4b" \
  --set apisixRoute.host="qwen4b-inference.example.com"
```
