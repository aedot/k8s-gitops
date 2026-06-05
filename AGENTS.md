# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Kubernetes GitOps home lab repository. [Flux](https://fluxcd.io/) watches `kubernetes/` and reconciles the cluster state from Git. [Renovate](https://docs.renovatebot.com/) creates PRs for dependency updates. The cluster runs on [Talos Linux](https://www.talos.dev/) with [Longhorn](https://longhorn.io/) for persistent storage.

## Common Commands

All tools are installed via `mise install` (see `.mise.toml`). Task automation uses `just`:

```bash
just -l                          # list all available commands

# Validate manifests
kustomize build kubernetes/apps/<namespace>/ | kubeconform -summary
kubeconform -summary -output json kubernetes/

# Flux operations
flux get kustomizations -A
flux logs -f --all-namespaces
flux reconcile kustomization cluster-apps --with-source

# Secret management (SOPS + age)
sops kubernetes/apps/<namespace>/secret.sops.yaml     # edit
sops -d kubernetes/apps/<namespace>/secret.sops.yaml  # decrypt/view
```

## Architecture

### GitOps Flow

Flux's `cluster-apps` Kustomization points at `./kubernetes/apps`. It recursively finds the top-level `kustomization.yaml` in each namespace directory and applies it. That file typically:
1. Declares `components: [../../components/sops, ../../components/namespace]`
2. Lists `resources:` referencing one or more `ks.yaml` files

Each `ks.yaml` is a **Flux Kustomization** that points at an `./app` subdirectory containing the actual `HelmRelease` and related manifests.

### Namespace/App Layout

```
kubernetes/apps/<namespace>/
├── kustomization.yaml       # Namespace-level: sops + namespace components + ks.yaml refs
└── <app>/
    ├── ks.yaml              # Flux Kustomization → ./app; lists components + dependsOn
    └── app/
        ├── kustomization.yaml   # Kustomize resources list
        ├── helmrelease.yaml     # HelmRelease (main deployment unit)
        ├── externalsecret.yaml  # ExternalSecret for secrets from Akeyless
        └── [pvc, configmap, etc.]
```

### Reusable Components (`kubernetes/components/`)

Components are attached to a Flux Kustomization via the `components:` field in `ks.yaml` (not in the namespace-level `kustomization.yaml`). Available components:

- `namespace` — creates the Namespace + Flux alerts
- `sops` — enables SOPS decryption for the Kustomization
- `postgres` — provisions a CloudNativePG cluster
- `dragonfly` — provisions a Dragonfly (Redis-compatible) instance
- `volsync` — adds PVC backup/restore via VolSync
- `gpu` — adds Intel GPU resource requests
- `zeroscaler` — enables zero-scaling for the workload

### Variable Substitution

Flux injects cluster-wide variables (e.g. `${SECRET_DOMAIN}`) into manifests via:
```yaml
postBuild:
  substituteFrom:
    - name: cluster-secrets
      kind: Secret
```
Use `${VAR_NAME}` syntax in HelmRelease `values:` for cluster-scoped variables.

### Secret Management

- Secrets at rest: `*.sops.yaml` files encrypted with SOPS + age key (`age.key`)
- Runtime secrets: ExternalSecret resources pull from Akeyless via `external-secrets` operator
- Renovate ignores `*.sops.*` files

### DNS / Ingress

Two ExternalDNS instances handle DNS:
- **internal** gateway → UniFi private DNS
- **external** gateway → Cloudflare public DNS

Ingress is managed via Envoy Gateway (HTTPRoute/Gateway API). Cloudflared provides the secure external tunnel.

### Bootstrap

Initial cluster setup (before Flux takes over) uses `helmfile` in `bootstrap/helmfile/`. The bootstrap order is: Cilium → CoreDNS → Spegel → cert-manager → external-secrets → flux-operator → flux-instance.

### Talos Configuration

Node OS config lives in `talos/`. Patches in `talos/patches/` are applied per scope: `global/`, `controller/`, `worker/`, or `<node-hostname>/`.

## CI (GitHub Actions)

- **flate** — on PRs touching `kubernetes/**`, diffs HelmRelease and Kustomization changes and posts them as PR comments
- **renovate** — runs Renovate on schedule to create dependency update PRs
- **labeler** — auto-labels PRs based on changed paths

## Adding a New Application

1. Create `kubernetes/apps/<namespace>/<app>/app/` with `helmrelease.yaml` and `kustomization.yaml`
2. Create `kubernetes/apps/<namespace>/<app>/ks.yaml` as a Flux Kustomization referencing `./app`, with `dependsOn`, `components`, and `postBuild.substituteFrom` as needed
3. Add `- ./<app>/ks.yaml` to the namespace's top-level `kustomization.yaml` resources
4. If a new namespace, create `kubernetes/apps/<namespace>/kustomization.yaml` with sops + namespace components
5. Commit and push — Flux reconciles automatically
