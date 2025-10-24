#!/usr/bin/env python3
"""Manage LiteLLM model registrations by auto-discovering KServe InferenceServices."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional


@dataclass
class ModelConfig:
    """Minimal model configuration."""

    name: str
    api_base: str
    model_type: str = "openai"
    litellm_params: Dict[str, Any] | None = None

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ModelConfig":
        if "name" not in data:
            raise ValueError("model entry missing 'name'")
        if "api_base" not in data:
            raise ValueError("model entry missing 'api_base'")

        litellm_params_raw = data.get("litellm_params") or {}
        if not isinstance(litellm_params_raw, dict):
            raise ValueError("'litellm_params' must be a mapping if provided")

        model_type = data.get("model_type", data.get("provider", "openai"))
        return cls(
            name=str(data["name"]),
            api_base=str(data["api_base"]),
            model_type=str(model_type),
            litellm_params=dict(litellm_params_raw),
        )


class LiteLLMClient:
    """Simple HTTP client for LiteLLM API."""

    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        timeout: int = 30,
    ) -> None:
        if not base_url.lower().startswith("http"):
            raise ValueError("base_url must include http/https scheme")
        if not api_key:
            raise ValueError("LiteLLM API key is required")
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def _request(
        self,
        method: str,
        path: str,
        payload: Optional[Dict[str, Any]] = None,
    ) -> Any:
        url = f"{self.base_url}{path}"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = urllib.request.Request(
            url=url, data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                body = response.read().decode("utf-8")
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", errors="ignore").strip()
            message = f"{method} {url} failed ({err.code}): {detail or err.reason}"
            raise RuntimeError(message) from None
        except urllib.error.URLError as err:
            raise RuntimeError(f"{method} {url} failed: {err.reason}") from None

    def health(self) -> bool:
        try:
            self._request("GET", "/health/readiness")
            return True
        except RuntimeError as err:
            sys.stderr.write(f"Health check failed: {err}\n")
            return False

    def list_models(self) -> List[str]:
        payload = self._request("GET", "/v1/models")
        items = payload.get("data", []) if isinstance(payload, dict) else []
        return [str(entry.get("id")) for entry in items if isinstance(entry, dict)]

    def register(self, model: ModelConfig) -> Dict[str, Any]:
        params = {
            "model": model.litellm_params.get("model")
            if model.litellm_params
            else f"{model.model_type}/{model.name}",
            "api_base": model.api_base,
        }
        if model.litellm_params:
            params.update(dict(model.litellm_params))

        payload = {
            "model_name": model.name,
            "litellm_params": params,
        }
        return self._request("POST", "/model/new", payload)

    def deregister(self, model_name: str) -> Dict[str, Any]:
        payload = {"model_name": model_name}
        return self._request("DELETE", "/model/delete", payload)


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=["list", "register", "deregister"],
        help="Action to perform",
    )
    parser.add_argument(
        "--model",
        help="Single model name (required for deregister; optional override for register)",
    )
    parser.add_argument(
        "--api-base",
        help="API base URL for single-model registration",
    )
    parser.add_argument(
        "--model-type",
        default="openai",
        help="Provider/model type (e.g., openai, openvino)",
    )
    parser.add_argument(
        "--litellm-url",
        default=os.getenv("LITELLM_URL", "http://litellm.litellm.svc.cluster.local:4000"),
        help="Base URL for the LiteLLM gateway",
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("LITELLM_API_KEY"),
        help="Bearer token for LiteLLM (defaults to LITELLM_API_KEY env)",
    )
    parser.add_argument(
        "--kserve-namespace",
        default=os.getenv("KSERVE_NAMESPACE", "kserve"),
        help="Namespace to query for KServe InferenceServices",
    )
    parser.add_argument(
        "--kubectl",
        default=os.getenv("KUBECTL_BIN", "kubectl"),
        help="kubectl binary used for KServe discovery",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.getenv("LITELLM_TIMEOUT", "30")),
        help="Request timeout in seconds",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print actions without sending requests",
    )
    return parser.parse_args(argv)


def discover_kserve_models(namespace: str, kubectl_bin: str) -> List[ModelConfig]:
    if shutil.which(kubectl_bin) is None:
        raise SystemExit(
            f"kubectl binary '{kubectl_bin}' not found. Use --model and --api-base to register manually."
        )

    command = [
        kubectl_bin,
        "get",
        "inferenceservices.serving.kserve.io",
        "-n",
        namespace,
        "-o",
        "json",
    ]
    try:
        output = subprocess.check_output(command, text=True)
    except subprocess.CalledProcessError as err:
        raise RuntimeError(
            f"kubectl discovery failed with exit code {err.returncode}: {err.output}"
        ) from None

    payload = json.loads(output or "{}")
    items: Iterable[Dict[str, Any]] = payload.get("items", []) if isinstance(payload, dict) else []
    discovered: List[ModelConfig] = []
    skipped_count = 0

    for item in items:
        metadata = item.get("metadata", {}) if isinstance(item, dict) else {}
        spec = item.get("spec", {}) if isinstance(item, dict) else {}
        status = item.get("status", {}) if isinstance(item, dict) else {}

        name = metadata.get("name")
        if not name:
            continue

        # Check if InferenceService is ready
        conditions = status.get("conditions", []) if isinstance(status, dict) else []
        is_ready = False
        ready_message = "Unknown status"
        for condition in conditions:
            if isinstance(condition, dict) and condition.get("type") == "Ready":
                is_ready = condition.get("status") == "True"
                ready_message = condition.get("message", condition.get("reason", "Not ready"))
                break
        
        if not is_ready:
            sys.stderr.write(f"⚠ Skipping {name}: {ready_message}\n")
            skipped_count += 1
            continue

        address = status.get("address", {}).get("url") if isinstance(status, dict) else None
        if not address:
            address = f"http://{name}-predictor-default.{namespace}.svc.cluster.local"

        address = str(address).rstrip("/")

        # Default to OpenVINO/KServe REST v3 path; customize per framework when detectable.
        framework = _detect_framework(spec)
        api_suffix = "/v3" if framework in {"openvino", "ovms"} else "/v1"
        api_base = f"{address}{api_suffix}"

        litellm_model_id = f"{framework}/{name}"
        litellm_params: Dict[str, Any] = {
            "model": litellm_model_id,
            "stream": True,
            "max_retries": 3,
        }

        discovered.append(
            ModelConfig(
                name=str(name),
                api_base=api_base,
                model_type=framework,
                litellm_params=litellm_params,
            )
        )

    if skipped_count > 0:
        sys.stderr.write(f"\n⚠ Skipped {skipped_count} InferenceService(s) that are not ready\n")
    
    return discovered


def _detect_framework(spec: Dict[str, Any]) -> str:
    if not isinstance(spec, dict):
        return "openai"

    predictor = spec.get("predictor", {})
    if isinstance(predictor, dict):
        model_spec = predictor.get("model")
        if isinstance(model_spec, dict):
            runtime = model_spec.get("runtime")
            if isinstance(runtime, str) and runtime:
                runtime_lower = runtime.lower()
                if "openvino" in runtime_lower:
                    return "openvino"
                return runtime_lower

            model_format = model_spec.get("modelFormat", {})
            if isinstance(model_format, dict):
                name = model_format.get("name")
                if isinstance(name, str) and name:
                    return name.lower()

        if "ovms" in predictor or predictor.get("modelFormat", {}).get("name") == "openvino":
            return "openvino"
        if "triton" in predictor:
            return "triton"
        if "sklearn" in predictor:
            return "sklearn"
        if "xgboost" in predictor:
            return "xgboost"
        containers = predictor.get("containers") or []
        if isinstance(containers, list) and containers:
            image = containers[0].get("image", "") if isinstance(containers[0], dict) else ""
            if "openvino" in image.lower():
                return "openvino"
            if "triton" in image.lower():
                return "triton"
            if "torch" in image.lower() or "pytorch" in image.lower():
                return "pytorch"
            if "tensorflow" in image.lower():
                return "tensorflow"

    return "openai"


def check_model_health(api_base: str, timeout: int = 10) -> bool:
    """Check if a model endpoint is responding."""
    # Try common health/readiness endpoints
    health_paths = ["/health", "/healthz", "/ready", "/v1/models", "/v3/models"]
    
    for path in health_paths:
        url = f"{api_base.rstrip('/')}{path}"
        try:
            request = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(request, timeout=timeout) as response:
                if response.status in (200, 204):
                    return True
        except (urllib.error.HTTPError, urllib.error.URLError, OSError):
            continue
    
    return False


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    if not args.api_key:
        raise SystemExit(
            "LiteLLM API key is required. Set LITELLM_API_KEY or use --api-key."
        )

    client = LiteLLMClient(
        base_url=args.litellm_url,
        api_key=args.api_key,
        timeout=args.timeout,
    )

    # Try health check but don't fail if it doesn't work
    try:
        if not client.health():
            sys.stderr.write(
                "⚠ LiteLLM health check returned non-ready status; continuing anyway...\n"
            )
    except Exception as e:
        sys.stderr.write(
            f"⚠ LiteLLM health check failed ({e}); continuing anyway...\n"
        )

    if args.command == "list":
        models = client.list_models()
        if not models:
            print("No models registered.")
        else:
            print("Registered models:")
            for name in models:
                print(f"  - {name}")
        return 0

    if args.command == "deregister":
        if not args.model:
            raise SystemExit("--model is required for deregister command")
        model = ModelConfig(
            name=args.model,
            api_base="",
            model_type=args.model_type,
        )
        if args.dry_run:
            print(f"DRY RUN: deregister {model.name}")
            return 0
        response = client.deregister(model.name)
        print(json.dumps(response, indent=2))
        return 0

    # register command
    models: List[ModelConfig]
    if args.model and args.api_base:
        # Single model registration
        litellm_params = {"model": f"{args.model_type}/{args.model}"}
        models = [ModelConfig(
            name=args.model,
            api_base=args.api_base,
            model_type=args.model_type,
            litellm_params=litellm_params,
        )]
    else:
        # Auto-discovery from KServe
        try:
            models = discover_kserve_models(args.kserve_namespace, args.kubectl)
        except RuntimeError as err:
            raise SystemExit(str(err)) from None
        if not models:
            raise SystemExit(
                "No KServe InferenceServices discovered. Use --model and --api-base to register manually."
            )

    exit_code = 0
    for model in models:
        if args.dry_run:
            print(f"DRY RUN: register {model.name} -> {model.api_base}")
            continue
        
        # Check model health before registration
        print(f"Checking health of {model.name} at {model.api_base}...")
        if not check_model_health(model.api_base, timeout=10):
            sys.stderr.write(f"⚠ Skipping {model.name}: Model endpoint not responding\n")
            sys.stderr.write(f"  Tried: {model.api_base}\n")
            exit_code = 1
            continue
        
        print(f"✓ Model {model.name} is responding")
        
        try:
            response = client.register(model)
            print(f"✓ Registered: {model.name}")
            if args.command == "list" or len(models) == 1:
                print(json.dumps(response, indent=2))
        except RuntimeError as err:
            sys.stderr.write(f"✗ Failed to register {model.name}: {err}\n")
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
