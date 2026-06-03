# Repository Structure Guide

This document provides a detailed breakdown of the repository structure and explains the purpose of each directory and key files.

## Root Level

```
k8s-gitops/
├── kubernetes/          # Kubernetes manifests (main GitOps source)
├── bootstrap/           # Cluster bootstrap scripts and initial setup
├── talos/              # Talos OS configuration and customization
├── docs/               # Documentation and reference guides
├── .github/            # GitHub specific config (workflows, templates)
├── .renovate/          # Renovate dependency update configuration
├── .venv/              # Python virtual environment (local dev)
├── .vscode/            # VS Code workspace settings
├── .private/           # Private configuration (git-ignored)
├── CLAUDE.md           # Claude AI project documentation (new)
├── ARCHITECTURE.md     # Architecture and design decisions (new)
├── README.md           # Project overview
├── LICENSE             # Repository license
├── justfile            # Task automation (just commands)
├── .mise.toml          # Development environment setup
├── .renovaterc.json5   # Main Renovate configuration
├── .sops.yaml          # SOPS encryption configuration
├── age.key             # Age encryption key (DO NOT COMMIT in real scenario)
├── kubeconfig          # Local Kubernetes config (git-ignored)
└── [other config files]
```

## kubernetes/ — Kubernetes Manifests

**Purpose**: Contains all Kubernetes workloads and system configuration deployed via Flux.

```
kubernetes/
├── apps/               # Application workloads organized by namespace
├── components/         # Reusable Kustomize components
└── flux/              # Flux CD system configuration
```

### kubernetes/apps/ — Application Namespaces

Each subdirectory represents a Kubernetes namespace with its workloads.

```
kubernetes/apps/
├── flux-system/                    # Flux CD system itself
│   ├── kustomization.yaml          # Top-level namespace setup
│   ├── ks.yaml                     # Flux Kustomization for Flux components
│   ├── namespace/
│   │   └── kustomization.yaml      # Namespace resource + common components
│   ├── flux-operator/              # Flux Operator HelmRelease
│   │   ├── app/kustomization.yaml
│   │   ├── ks.yaml
│   │   └── helmrelease.yaml
│   └── flux-instance/              # Flux Instance HelmRelease
│       ├── app/kustomization.yaml
│       ├── ks.yaml
│       └── helmrelease.yaml
│
├── cert-manager/                   # Certificate management
│   ├── kustomization.yaml
│   ├── ks.yaml
│   ├── namespace/
│   └── cert-manager/
│       ├── app/kustomization.yaml
│       └── helmrelease.yaml
│
├── kube-system/                    # Core Kubernetes components
│   ├── kustomization.yaml
│   ├── ks.yaml
│   └── [system components]/
│
├── longhorn-system/                # Persistent storage
│   ├── kustomization.yaml
│   ├── ks.yaml
│   └── longhorn/
│       ├── app/kustomization.yaml
│       └── helmrelease.yaml
│
├── observability/                  # Monitoring & logging
│   ├── kustomization.yaml
│   ├── ks.yaml
│   ├── prometheus/
│   ├── grafana/
│   ├── alertmanager/
│   └── [monitoring stack]/
│
├── security/                       # Security tools & policies
│   ├── kustomization.yaml
│   ├── ks.yaml
│   └── [security components]/
│
├── network/                        # Networking components
│   ├── kustomization.yaml
│   ├── ks.yaml
│   ├── cilium/                     # CNI
│   ├── external-dns/               # DNS management (private + public)
│   ├── cloudflared/                # Cloudflare tunnel
│   └── envoy-gateway/              # Ingress gateway
│
├── media/                          # Media services (optional user apps)
│   ├── kustomization.yaml
│   ├── ks.yaml
│   └── [media apps]/
│
├── dbms/                           # Database services
│   ├── kustomization.yaml
│   ├── ks.yaml
│   └── [database workloads]/
│
├── external-secrets/               # Secret management operator
│   ├── kustomization.yaml
│   ├── ks.yaml
│   └── external-secrets-operator/
│
├── actions-runner-system/          # GitHub self-hosted runners
│   ├── kustomization.yaml
│   ├── ks.yaml
│   └── actions-runner-controller/
│
├── system-upgrade/                 # System upgrade controller
├── volsync-system/                 # Volume backup/restore
├── default/                        # Default namespace (if used)
└── downloads/                      # Download services (optional)
```

**Key Files in Each Namespace**:

- `kustomization.yaml` — Top-level: declares namespace resource and `ks.yaml` Kustomization
- `ks.yaml` — Flux Kustomization: references app's HelmRelease/manifests
- `namespace/kustomization.yaml` — Namespace component: applies labels, SOPS, alerts
- `[app]/app/kustomization.yaml` — HelmRelease or K8s manifests for the app
- `[app]/app/helmrelease.yaml` — Flux HelmRelease (if using Helm)
- `[app]/app/values.yaml` — Helm values (if using Helm)

### kubernetes/components/ — Reusable Kustomize Components

Components provide shared resources that can be included in multiple namespaces.

```
kubernetes/components/
├── namespace/                      # Namespace template component
│   ├── kustomization.yaml          # Exports namespace and subcomponents
│   ├── namespace.yaml              # Namespace resource with labels
│   ├── alerts/
│   │   └── alertmanager/           # Alertmanager rules
│   │       └── kustomization.yaml
│   ├── [other namespace-wide components]/
│   └── README.md                   # Usage guide
│
├── postgres/                       # PostgreSQL component
│   ├── kustomization.yaml
│   ├── secret.sops.yaml            # Encrypted credentials
│   ├── configmap.yaml
│   ├── deployment.yaml (or HelmRelease)
│   └── README.md
│
├── sops/                           # SOPS secret encryption component
│   ├── kustomization.yaml
│   ├── secret.yaml                 # SOPS encryption key reference
│   └── README.md
│
├── dragonfly/                      # Redis cache (Dragonfly)
├── gpu/                            # GPU device plugin
├── volsync/                        # Volume sync component
├── zeroscaler/                     # Pod scaling component
└── [other reusable components]/
```

**Component Usage**: Include in namespace `kustomization.yaml`:
```yaml
components:
  - ../../components/namespace
  - ../../components/sops
```

### kubernetes/flux/ — Flux System Configuration

```
kubernetes/flux/
├── config/                         # Flux operator configuration
├── vars/                           # Cluster variables
│   └── cluster.yaml               # Cluster name, domain, etc.
└── [Flux system manifests]
```

## bootstrap/ — Cluster Bootstrap

**Purpose**: Initial setup and configuration scripts for bootstrapping a new Talos + Kubernetes cluster.

```
bootstrap/
├── README.md                       # Bootstrap instructions
├── scripts/
│   ├── bootstrap.sh                # Main bootstrap script
│   ├── setup-talos.sh              # Talos-specific setup
│   ├── setup-flux.sh               # Flux initialization
│   └── [other setup scripts]
├── terraform/ (or similar)         # Infrastructure as Code (optional)
└── [cluster initialization config]
```

## talos/ — Talos OS Configuration

**Purpose**: Talos Linux OS-level configuration (machine config, patches, customizations).

```
talos/
├── clusterconfig/                  # Generated cluster config (git-ignored)
│   ├── talosconfig                 # Talos client config
│   ├── controlplane.yaml           # Control plane machine config
│   ├── worker.yaml                 # Worker node machine config
│   └── [per-node configs]
├── patches/
│   ├── README.md                   # Patch documentation
│   ├── common/                     # Common patches for all nodes
│   ├── controlplane/               # Control plane specific patches
│   ├── worker/                     # Worker node specific patches
│   └── [custom patches]
├── talconfig.yaml                  # Talhelper configuration (if used)
└── [other Talos config]
```

## docs/ — Documentation

**Purpose**: Reference guides, cluster architecture docs, and operational guides.

```
docs/
├── STRUCTURE.md                    # This file - repo structure guide
├── CONTRIBUTING.md                 # Contribution guidelines (new)
├── cluster-template.md             # Reference to cluster-template repo
├── postgres.md                     # PostgreSQL setup guide
├── notes/
│   ├── rclone.md                  # Rclone backup configuration
│   └── [operational notes]
├── assets/                         # Diagrams, images
│   └── [architecture diagrams]
└── script/
    └── [documentation scripts]
```

## .github/ — GitHub Configuration

**Purpose**: GitHub-specific workflows, issue templates, and CI/CD.

```
.github/
├── workflows/
│   ├── lint.yaml                   # YAML lint, shellcheck, etc.
│   ├── validate.yaml               # Kustomize/Helm validation
│   ├── [other CI workflows]
│   └── renovate.yaml (optional)    # Renovate trigger
├── ISSUE_TEMPLATE/
│   ├── bug_report.md
│   ├── feature_request.md
│   └── [other templates]
├── PULL_REQUEST_TEMPLATE.md        # PR template
├── CODE_OF_CONDUCT.md
├── SECURITY.md
└── [other GitHub config]
```

## .renovate/ — Renovate Configuration

**Purpose**: Modular Renovate bot configuration files for dependency updates.

```
.renovate/
├── autoMerge.json5                 # Auto-merge rules
├── changelogs.json5                # Changelog settings
├── customManagers.json5            # Custom dependency patterns (pipx, etc.)
├── grafanaDashboards.json5         # Grafana dashboard updates
├── groups.json5                    # Dependency grouping rules
├── labels.json5                    # PR label rules
├── overrides.json5                 # Package-specific overrides
└── semanticCommits.json5           # Commit message formatting
```

**Main Config**: `.renovaterc.json5` extends these files:
```json5
extends: [
  'github>aedot/k8s-gitops//.renovate/autoMerge.json5',
  'github>aedot/k8s-gitops//.renovate/groups.json5',
  // ... other extensions
]
```

## Root Configuration Files

### .mise.toml
Defines development environment setup via [mise](https://github.com/jdx/mise).

**Defines**:
- Python version & venv
- Tool versions (kubectl, flux2, talosctl, helm, etc.)
- Environment variables (KUBECONFIG, SOPS_*, etc.)
- Post-install hooks (lefthook)

**Usage**:
```bash
mise install    # Install all tools
mise install python  # Install specific tool
```

### .renovaterc.json5
Main Renovate configuration file.

**Key Settings**:
- Extends modular configs from `.renovate/`
- Ignores paths: `**/resources/**`, `**/*.sops.*`
- Flux monitoring enabled
- Semantic commits enabled
- Auto-merge for low-risk updates (configured in `.renovate/autoMerge.json5`)

### .sops.yaml
SOPS encryption configuration.

**Defines**:
- Age encryption key reference (`age.key`)
- Encryption scope for `.sops.yaml` files
- Decryption rules for external-secrets operator

**Example**:
```yaml
creation_rules:
  - path_regex: \.sops\.yaml$
    age: |
      age1...truncated...
```

### justfile
Task automation using [just](https://github.com/casey/just).

**Groups**:
- `bootstrap:*` — Cluster bootstrap commands
- `kubernetes:*` — Kubernetes operations
- `talos:*` — Talos OS operations

**Usage**:
```bash
just -l             # List all commands
just bootstrap:...  # Run bootstrap tasks
```

### .editorconfig, .gitattributes, .gitignore
Standard Git and editor configuration.

## Git-Ignored Paths (Important)

**Should NOT be committed**:
- `kubeconfig` — Local K8s credentials
- `.venv/` — Python virtual environment
- `talos/clusterconfig/` — Generated machine configs
- `age.key` — Encryption key (in this example, but should use secrets management)
- `.private/` — Private configuration
- `*.sops.yaml` (encrypted files) — Encrypted secrets go in Git, plaintext never

## File Naming Conventions

### Kubernetes Manifests
- `namespace.yaml` — Namespace resource
- `kustomization.yaml` — Kustomize configuration
- `ks.yaml` — Flux Kustomization resource
- `helmrelease.yaml` — Flux HelmRelease resource
- `configmap.yaml` — ConfigMap
- `secret.sops.yaml` — Encrypted Secret
- `deployment.yaml`, `statefulset.yaml`, etc. — Standard K8s resources

### Configuration Files
- `.sops.yaml` — SOPS configuration
- `.renovaterc.json5` — Renovate main config
- `*.json5` — Modular Renovate configs (JSON5 format)
- `.mise.toml` — Mise tool configuration
- `talconfig.yaml` — Talhelper configuration

## Summary: Typical Workflow

1. **Local Development** (`.mise.toml`):
   - Install tools: `mise install`
   - Validate manifests: `kubeconform`

2. **Create/Update Resource** (kubernetes/apps/):
   - Add to namespace: `kubernetes/apps/{namespace}/{app}/`
   - Create HelmRelease: `app/helmrelease.yaml`
   - Commit to Git

3. **Flux Deploys** (kubernetes/ + Flux):
   - Flux detects change in Git
   - Flux applies namespace + HelmRelease
   - Workload deployed to cluster

4. **Renovate Updates** (.renovate/ + Renovate):
   - Detects new version of dependency
   - Creates PR with update
   - Auto-merges (if configured)
   - Flux re-deploys with new version

5. **Backup/Recovery** (bootstrap/ + talos/):
   - Git is source of truth
   - Bootstrap scripts re-create cluster
   - Volsync restores persistent volumes
