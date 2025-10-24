# Ubuntu 24.04 Compatibility Notes

## Python Virtual Environment Support

**Issue**: Ubuntu 24.04 enforces PEP 668, which prevents installing Python packages directly to system Python with `pip install`. You'll see this error:

```
error: externally-managed-environment

× This environment is externally managed
╰─> To install Python packages system-wide, try apt install
    python3-xyz, where xyz is the package you are trying to
    install.
```

**Solution**: All Phase 0 deployment scripts now automatically create and use Python virtual environments.

## What Was Changed

### Phase 0 Deployment Scripts

Both `deploy-single-node.sh` and `deploy-multi-node.sh` now:

1. **Install `python3-venv`** package:
   ```bash
   sudo apt-get install -y git python3 python3-pip python3-venv sshpass
   ```

2. **Create virtual environment** at `$KUBESPRAY_DIR/.kubespray-venv`:
   ```bash
   python3 -m venv "$KUBESPRAY_DIR/.kubespray-venv"
   ```

3. **Activate venv before installing requirements**:
   ```bash
   source "$VENV_DIR/bin/activate"
   pip install --upgrade pip
   pip install -r requirements.txt
   ```

4. **Run Ansible with venv activated**: All subsequent Kubespray commands run within the virtual environment.

## Compatibility Matrix

| OS Version | Virtual Environment | Behavior |
|------------|---------------------|----------|
| Ubuntu 22.04 and earlier | Optional | Works with or without venv |
| Ubuntu 24.04+ | **Required** | Automatically created by scripts |
| Debian 12+ | **Required** | Same as Ubuntu 24.04 |
| RHEL 9+ | Optional | System packages still allowed |

## Manual Venv Management

If you need to manage the venv manually:

### Activate existing venv:
```bash
source <project-root>/kubespray/.kubespray-venv/bin/activate
```

### Install additional packages:
```bash
source <project-root>/kubespray/.kubespray-venv/bin/activate
pip install <package-name>
```

### Deactivate venv:
```bash
deactivate
```

### Delete and recreate venv:
```bash
rm -rf <project-root>/kubespray/.kubespray-venv
cd <project-root>/kubespray
python3 -m venv .kubespray-venv
source .kubespray-venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

## Phases That Use Python

| Phase | Python Usage | Venv Required? |
|-------|--------------|----------------|
| Phase 0 | Kubespray Ansible playbooks | ✅ Yes (automatic) |
| Phase 1-3 | None (pure Kubernetes YAML) | ❌ No |
| Phase 4 | Model Watcher (runs in container) | ❌ No (uses Docker) |
| Phase 5 | Load testing (optional) | ⚠️ Optional |

## Testing on Ubuntu 24.04

To verify venv support:

```bash
# Check if venv is created during deployment
cd /home/ubuntu/ai-stack-production/phase0-kubernetes-cluster
./deploy-single-node.sh

# Verify venv exists
ls -la <project-root>/kubespray/.kubespray-venv

# Check pip packages in venv
source <project-root>/kubespray/.kubespray-venv/bin/activate
pip list | grep ansible
```

## Troubleshooting

### Error: "externally-managed-environment"
**Symptom**: `pip install` fails even though venv should be activated

**Solution**:
```bash
# Verify venv is activated (should show venv path)
which python
which pip

# If not activated, activate manually
source <project-root>/kubespray/.kubespray-venv/bin/activate
```

### Error: "No module named 'ansible'"
**Symptom**: Ansible commands fail after installation

**Solution**:
```bash
# Reinstall requirements in venv
cd <project-root>/kubespray
source .kubespray-venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

### Old Ubuntu version behavior
**Symptom**: Venv creation seems unnecessary on Ubuntu 22.04

**Solution**: The scripts are forward-compatible. On older Ubuntu versions, venv is created but not strictly required. This ensures the same script works across all Ubuntu versions.

## Best Practices

1. **Always activate venv** before manual Kubespray operations
2. **Don't use sudo with pip** inside venv (defeats the purpose)
3. **Recreate venv** if you upgrade system Python version
4. **Keep venv separate** - one per Kubespray installation

## Related Links

- [PEP 668 – Marking Python base environments as "externally managed"](https://peps.python.org/pep-0668/)
- [Python venv documentation](https://docs.python.org/3/library/venv.html)
- [Ubuntu 24.04 Release Notes](https://discourse.ubuntu.com/t/noble-numbat-release-notes/39890)
