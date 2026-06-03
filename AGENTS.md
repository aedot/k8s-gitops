# k8s-gitops Project Guide

## Overview

This is a **Kubernetes GitOps home infrastructure repository** managed with Flux CD, Renovate, and GitHub Actions. The cluster runs on [Talos Linux](https://www.taloslinux.com/) with persistent storage via [Longhorn](https://longhorn.io/).

**Key tools:** Kubernetes, Flux, Renovate, Talos, Kustomize, Helm

## Directory Structure

```
kubernetes/
├── apps/              # Kubernetes workloads organized by namespace
│   ├── flux-system/       # Flux CD system
│   ├── cert-manager/      # Certificate management
│   ├── kube-system/       # Core Kubernetes components
│   ├── longhorn-system/   # Persistent storage
│   ├── observability/     # Monitoring & logging
│   ├── security/          # Security tools
│   ├── network/           # Networking (Cilium, ExternalDNS)
│   ├── media/             # Media services
│   ├── dbms/              # Databases
│   └── [other namespaces]/
├── components/        # Reusable Kustomize components
│   ├── namespace/         # Namespace templates with common components
│   ├── postgres/          # PostgreSQL component
│   ├── sops/              # SOPS secrets encryption
│   └── [other components]/
└── flux/              # Flux CD system configuration

bootstrap/            # Initial cluster bootstrap scripts
talos/               # Talos OS configuration
docs/                # Documentation and reference guides
.renovate/           # Renovate bot configuration files
```

## Architecture & Patterns

### GitOps Flow
1. **Git is source of truth** - All infrastructure defined in this repo
2. **Flux watches** - `kubernetes/apps` folder recursively
3. **Kustomization applies** - Finds top-level `kustomization.yaml` per directory
4. **HelmReleases deploy** - Helm charts managed via Flux
5. **Renovate updates** - PRs for dependency/container image updates

### Namespace Structure
- Each namespace in `kubernetes/apps/{namespace}/` contains:
  - `kustomization.yaml` - Namespace resource + Flux Kustomizations
  - `ks.yaml` - HelmRelease or other workload resources
  - Optional `namespace/` subdirectory with additional resources

### Reusable Components
Located in `kubernetes/components/`:
- **namespace** - Template for namespace setup with common components (SOPS, alerts, etc.)
- **postgres** - PostgreSQL database component
- **sops** - SOPS-based secret encryption setup
- **dragonfly** - Redis cache component
- **gpu** - GPU device plugin
- **zeroscaler** - Zero-scaler for pod scaling
- **volsync** - Volume backup/restore

### Secrets Management
- Uses **SOPS + age encryption** (see `.sops.yaml` and `age.key`)
- Secrets stored as `*.sops.yaml` files
- Renovate ignores `*.sops.*` files (configured in `.renovaterc.json5`)

### Dependency Management
- **Renovate** monitors entire repo for updates
- Configuration: `.renovaterc.json5` with modular configs in `.renovate/` directory
- Flux monitoring: automatically applies merged updates to cluster
- Auto-merge enabled for certain dependency types

## Development Environment

### Prerequisites (via `mise`)
- Python 3.14.5
- Kubernetes tooling: `kubectl`, `kubeconform`, `kustomize`
- Flux: `flux2` 2.8.8
- Talos: `talosctl`, `talhelper` 3.1.10
- Secrets: `sops`, `age`, `jq`, `yq`
- Other: `helmfile`, `just`, `gum`, `gh`, `sd`, `cue`

Install all tools:
```bash
mise install
```

### Environment Variables (from `.mise.toml`)
- `KUBECONFIG` - Points to local kubeconfig
- `SOPS_CONFIG` - SOPS encryption configuration
- `SOPS_AGE_KEY_FILE` - Age encryption key for SOPS
- `TALOSCONFIG` - Talos cluster config
- `JUST_UNSTABLE` - Enable unstable just features

### Available Commands
Run `just -l` to list all available commands (organized by groups):
- `bootstrap:*` - Cluster bootstrap commands
- `kubernetes:*` - Kubernetes operations
- `talos:*` - Talos OS operations

## Common Tasks

### Adding a New Application
1. Create namespace directory: `kubernetes/apps/{namespace}/{app}/`
2. Create `app/kustomization.yaml` with HelmRelease or Kubernetes resources
3. Add to namespace's top-level `kustomization.yaml` via `ks.yaml`
4. Commit and push - Flux automatically detects and applies

### Managing Secrets
1. Encrypt with SOPS: `sops kubernetes/apps/namespace/secret.sops.yaml`
2. Renovate will skip `*.sops.*` files
3. Flux handles decryption via external-secrets-operator

### Updating Dependencies
- Renovate automatically creates PRs for:
  - Docker image updates
  - Helm chart versions
  - Kubernetes API versions
  - GitHub Actions
- Check `.renovate/` configs for rules and auto-merge policies

### Validating Manifests
```bash
kubeconform -summary -output json kubernetes/
kustomize build kubernetes/apps/{namespace}/ | kubeconform -summary
```

## Key Components in Cluster

### Core
- **Flux** - GitOps controller
- **Talos Linux** - Immutable OS
- **Cilium** - eBPF-based networking
- **Cert-manager** - SSL certificate automation

### Storage & Databases
- **Longhorn** - Persistent block storage
- **Volsync** - Backup/restore (uses Longhorn)
- **PostgreSQL** - DBMS (via component)
- **Dragonfly** - Redis cache alternative

### External Connectivity
- **External-DNS** - Dual instance for private (UniFi) + public (Cloudflare) DNS
- **Cloudflared** - Cloudflare tunnel for secure ingress
- **Envoy Gateway** - HTTPRoute/Gateway API management

### Observability & Security
- **Kube-prometheus-stack** - Monitoring (Prometheus, Grafana, Alertmanager)
- **External-secrets** - Secret management via Akeyless
- **Security systems** - TBD per deployment

### Multi-tenancy & Scaling
- **Multus** - Multi-homed pod networking
- **Actions-runner-controller** - Self-hosted GitHub runners
- **Zeroscaler** - Pod scaling optimization
- **GPU device plugin** - GPU workload support

## Important Files

- `.renovaterc.json5` - Main Renovate config (extends modular configs)
- `.renovate/` - Modular Renovate configs (autoMerge, groups, overrides, etc.)
- `.sops.yaml` - SOPS configuration for secret encryption
- `.mise.toml` - Development environment setup (Python, tools versions)
- `justfile` - Task automation commands
- `bootstrap/` - Initial cluster setup procedures

## Troubleshooting

### Flux not applying changes
```bash
flux check
flux get kustomizations -A
flux logs -f --all-namespaces
```

### Secret decryption issues
```bash
sops -d kubernetes/apps/{namespace}/secret.sops.yaml
# Check age.key and .sops.yaml configuration
```

### Kustomize validation
```bash
kustomize build kubernetes/apps/{namespace}/ --enable-helm
```

### Check Renovate
- Dashboard: GitHub PR comments with update summaries
- Configuration errors: Check `.renovaterc.json5` syntax
- Logs: `.renovate/` directory for rule matching

## Standards & Conventions

- **Namespaces**: One per logical component/service area
- **Naming**: Lowercase, hyphenated (Kubernetes convention)
- **Labels**: Applied via namespace component (standard across deployments)
- **Resources**: HelmRelease preferred over raw manifests for maintainability
- **Secrets**: Always encrypted with SOPS, never committed in plaintext

## Related Documentation

- [Cluster Template Guide](docs/cluster-template.md) - Reference implementation
- [PostgreSQL Component](kubernetes/components/postgres/README.md) - Database setup
- [Longhorn Documentation](kubernetes/apps/longhorn-system/longhorn/README.md) - Storage
- [Talos Patches](talos/patches/README.md) - OS-level customizations
