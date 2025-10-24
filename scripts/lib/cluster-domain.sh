#!/bin/bash
# Utilities for resolving the Kubernetes cluster domain.

# Echo the first search domain configured in CoreDNS, fallback to cluster.local.
detect_cluster_domain() {
    local corefile
    corefile=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
    if [ -z "$corefile" ]; then
        echo "cluster.local"
        return 0
    fi

    local domain
    domain=$(printf '%s\n' "$corefile" | awk '/^\s*kubernetes /{print $2; exit}')
    if [ -n "$domain" ]; then
        echo "$domain"
        return 0
    fi

    echo "cluster.local"
}

# Ensure CLUSTER_DOMAIN is set and exported for downstream scripts.
ensure_cluster_domain() {
    if [ -n "${CLUSTER_DOMAIN:-}" ]; then
        echo "$CLUSTER_DOMAIN"
        return 0
    fi

    local detected
    detected=$(detect_cluster_domain)
    CLUSTER_DOMAIN="$detected"
    export CLUSTER_DOMAIN
    echo "$CLUSTER_DOMAIN"
}
