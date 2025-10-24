#!/bin/bash
# Download and prepare Knative Serving manifests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KNATIVE_VERSION="v1.19.4"
KSERVE_VERSION="v0.15.2"

echo "Downloading Knative Serving CRDs..."
curl -sL https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-crds.yaml \
    -o 00-knative-serving-crds.yaml

echo "Downloading Knative Serving Core..."
curl -sL https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-core.yaml \
    -o 01-knative-serving-core.yaml

echo "Downloading Knative Istio Networking..."
curl -sL https://github.com/knative/net-istio/releases/download/knative-${KNATIVE_VERSION}/net-istio.yaml \
    -o 02-knative-istio-networking.yaml

echo "Downloading KServe manifest..."
curl -sL https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml \
    -o 10-kserve.yaml

echo "Downloads complete!"
