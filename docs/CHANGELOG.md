# Changelog - AI Stack Production

All notable changes to this project will be documented in this file.

## [1.1.0] - 2025-10-18

### Added - OpenVINO ClusterServingRuntime

#### New Features
- **ClusterServingRuntime**: Modern KServe runtime approach replacing legacy predictor configuration
- **Multi-Format Support**: Single runtime supports OpenVINO IR, ONNX, TensorFlow, and HuggingFace models
- **Auto-Selection**: Automatic runtime selection based on `modelFormat.name` in InferenceService
- **HuggingFace Integration**: Direct model deployment from HuggingFace Hub with `--source_model` argument
- **Security**: Non-root container (UID 5000), dropped capabilities, no privilege escalation

#### New Files
- `phase2-knative-kserve/11-openvino-runtime.yaml`: ClusterServingRuntime definition
- `phase2-knative-kserve/OPENVINO_RUNTIME.md`: Comprehensive runtime documentation (400+ lines)
- `phase2-knative-kserve/README.md`: Complete Phase 2 guide with ClusterServingRuntime usage
- `phase2-knative-kserve/EXAMPLES.yaml`: 8 complete deployment examples
- `phase2-knative-kserve/QUICK_DEPLOY.md`: Quick reference guide for model deployment

#### Modified Files
- `phase2-knative-kserve/12-kserve-config.yaml`: Simplified, removed old predictor config
- `phase2-knative-kserve/90-sample-inferenceservice.yaml`: **Updated to use HuggingFace template (Qwen3-8B-INT4)**
- `phase2-knative-kserve/deploy-phase2.sh`: Added runtime deployment step, updated model name

#### Technical Details
**ClusterServingRuntime Configuration**:
- Base Image: `openvino/model_server:2025.3.0`
- Protocols: REST (v1, v2), gRPC (grpc-v2)
- Resource Requests: 1 CPU, 2Gi memory
- Resource Limits: 2 CPU, 4Gi memory
- Prometheus Metrics: `/metrics:8080`

**Supported Model Formats** (priority order):
1. OpenVINO IR (priority 1)
2. ONNX (priority 2)
3. TensorFlow (priority 3)
4. HuggingFace (priority 4)

#### Benefits
- ✅ Reusable runtime across all InferenceServices
- ✅ Centralized configuration management
- ✅ Easier to update model server version
- ✅ Support for multiple model formats
- ✅ Follows KServe best practices

#### Migration Guide
**Old Approach** (Deprecated):
```yaml
spec:
  predictor:
    containers:
    - name: kserve-container
      image: openvino/model_server:2025.3.0
      args: [...]
```

**New Approach** (Recommended - HuggingFace Hub):
```yaml
spec:
  predictor:
    model:
      runtime: kserve-openvino
      modelFormat:
        name: huggingface
      args:
        - --source_model=OpenVINO/Qwen3-8B-int4-ov
        - --model_repository_path=/tmp
        - --task=text_generation
        - --target_device=CPU
```

**Benefits**:
- ✅ No storage setup required (downloads from HuggingFace)
- ✅ Simplified YAML (70% less code)
- ✅ Reusable runtime across all models
- ✅ Support for multiple model formats

#### Reference
- Upstream Source: [dtrawins/kserve OpenVINO Runtime](https://github.com/dtrawins/kserve/blob/openvino/config/runtimes/kserve-openvino.yaml)
- KServe Docs: [ClusterServingRuntime Guide](https://kserve.github.io/website/latest/modelserving/servingruntimes/)

---

## [1.0.1] - 2025-10-18

### Added - Ubuntu 24.04 Support

#### Python Virtual Environment
- Automatic venv creation for Kubespray on Ubuntu 24.04+
- Fixes PEP 668 "externally-managed-environment" errors
- Backward compatible with Ubuntu 20.04 and 22.04

#### New Files
- `UBUNTU_24.04_NOTES.md`: Complete compatibility guide

#### Modified Files
- `phase0-kubernetes-cluster/deploy-single-node.sh`: Added venv creation
- `phase0-kubernetes-cluster/deploy-multi-node.sh`: Added venv creation
- `phase0-kubernetes-cluster/README.md`: Added Ubuntu 24.04 notes
- `README.md`: Added Ubuntu 24.04 compatibility note

#### Technical Details
- Virtual Environment Location: `<project-root>/kubespray/.kubespray-venv`
- Package: `python3-venv` automatically installed
- Activation: Automatic in deployment scripts

---

## [1.0.0] - 2025-10-18

### Initial Release - Complete Production Stack

#### Core Components
- **Phase 0**: Kubernetes cluster installation via Kubespray v2.28.1
- **Phase 1**: Istio service mesh with STRICT mTLS
- **Phase 2**: Knative Serving + KServe model serving
- **Phase 3**: LiteLLM API router with Redis cache and PostgreSQL
- **Phase 4**: Automatic model registration controller
- **Phase 5**: Performance optimization and load testing

#### Architecture
- **Istio-first**: Service mesh as L7 gateway
- **Serverless**: Scale-to-zero for cost efficiency
- **High Concurrency**: 1000+ concurrent requests
- **Auto-Discovery**: Automatic model registration
- **Security**: mTLS, RBAC, AuthorizationPolicies

#### Technology Stack
- Kubespray v2.28.1 → Kubernetes v1.32.8
- Istio 1.23.2 (minimal profile)
- Knative Serving v1.19.4
- KServe v0.15.2
- OpenVINO Model Server 2025.3.0
- LiteLLM (latest)
- PostgreSQL 16-alpine
- Redis 7-alpine

#### Documentation
- 4 comprehensive guides (README, QUICK_START, PROJECT_SUMMARY, START_HERE)
- Phase-specific documentation
- Troubleshooting guides
- Performance tuning recommendations

#### Deployment
- 7 automated deployment scripts
- One-command full stack deployment
- Phase-by-phase validation
- Comprehensive error handling

---

## Version History

| Version | Date | Description |
|---------|------|-------------|
| 1.1.0 | 2025-10-18 | OpenVINO ClusterServingRuntime implementation |
| 1.0.1 | 2025-10-18 | Ubuntu 24.04 Python venv support |
| 1.0.0 | 2025-10-18 | Initial production-ready release |

---

## Upgrade Instructions

### From 1.0.x to 1.1.0

1. **Pull latest changes** (if using git)
2. **No breaking changes** - existing InferenceServices continue to work
3. **Optional**: Migrate to ClusterServingRuntime approach for new models
4. **Deploy new runtime**:
   ```bash
   cd phase2-knative-kserve
   kubectl apply -f 11-openvino-runtime.yaml
   ```
5. **Verify**:
   ```bash
   kubectl get clusterservingruntimes.serving.kserve.io
   ```

### Migration (Optional)

To migrate existing InferenceServices to use ClusterServingRuntime:

1. Update InferenceService YAML to use `model` spec instead of `containers`
2. Specify `modelFormat.name: openvino`
3. Optionally specify `runtime: kserve-openvino`
4. Redeploy InferenceService

See [Phase 2 README](phase2-knative-kserve/README.md) for examples.

---

## Contributing

When adding new features:
1. Update version in main README.md
2. Add entry to this CHANGELOG.md
3. Update relevant phase documentation
4. Test deployment scripts
5. Update PROJECT_SUMMARY.md if architecture changes

---

## References

- [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
- [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
