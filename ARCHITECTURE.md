# k8s-gitops Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Repository                         │
│  (kubernetes/ + bootstrap/ + talos/ + docs/)               │
└────────────────────┬────────────────────────────────────────┘
                     │
         ┌───────────┼───────────┐
         │           │           │
    ┌────▼──┐   ┌────▼──┐   ┌───▼────┐
    │ Flux  │   │Renovate│   │Actions │
    │ Sync  │   │  Bot   │   │ Runners │
    └────┬──┘   └────┬──┘   └───┬────┘
         │           │           │
         │      (Creates PRs)    │
         │           │           │
    ┌────▼───────────▼───────────▼────┐
    │    Kubernetes Cluster (Talos)    │
    │  ┌──────────────────────────────┐│
    │  │  Flux Kustomization          ││ Applies manifests
    │  │  HelmRelease Controllers     ││
    │  └──────────────────────────────┘│
    │  ┌──────────────────────────────┐│
    │  │  Workload Namespaces         ││
    │  │  (apps/*, flux-system, etc)  ││
    │  └──────────────────────────────┘│
    │  ┌──────────────────────────────┐│
    │  │  Storage (Longhorn)          ││
    │  │  Networking (Cilium/Multus)  ││
    │  │  Ingress (Envoy Gateway)     ││
    │  └──────────────────────────────┘│
    └────────────────────────────────────┘
```

## Component Layers

### 1. Infrastructure Layer (Talos + Hardware)
- **OS**: Talos Linux (immutable, Kubernetes-native)
- **Distribution**: Semi hyper-converged (compute + storage on same nodes)
- **Networking**: Cilium eBPF, Multus for advanced networking
- **Storage Backend**: Longhorn (distributed block storage)

### 2. Kubernetes Core
- **API Server, etcd, kubelet, controller-manager** - Standard K8s
- **CNI**: Cilium (eBPF-based, replaces standard networking)
- **Storage**: Longhorn (custom PVCs)
- **Ingress**: Envoy Gateway + Gateway API

### 3. GitOps Platform (Flux)
```
Flux Source Controller
├── Monitors kubernetes/ folder
├── Detects kustomization.yaml changes
└── Triggers reconciliation

Flux Kustomization Controller
├── Builds Kustomizations with overlays
├── Applies namespace-specific resources
└── Manages HelmReleases

Flux Helm Controller
├── Manages Helm repositories
├── Applies HelmReleases
└── Updates charts on version change
```

### 4. Dependency Management (Renovate)
- Scans entire repository (except `*.sops.*`)
- Creates PRs for:
  - Container image updates (with pinned digests)
  - Helm chart updates
  - GitHub Actions updates (pinned to commit SHA)
  - Kubernetes API version upgrades
  - Tool version updates in `.mise.toml`
- Auto-merges low-risk updates based on `.renovate/` rules

### 5. Application Layer
Organized by namespace in `kubernetes/apps/`:
- **System**: flux-system, kube-system, cert-manager, external-secrets
- **Networking**: network (Cilium, ExternalDNS, Cloudflared)
- **Storage**: longhorn-system, volsync-system
- **Observability**: observability (Prometheus, Grafana, Alertmanager)
- **Security**: security (network policies, RBAC)
- **Workloads**: media, dbms, default (user applications)
- **Automation**: system-upgrade, actions-runner-system

## Data Flow

### Deployment Flow
```
1. User commits code to github.com/aedot/k8s-gitops
   └─> Git branch/tag created

2. Flux Source Controller detects change
   └─> Pulls latest kubernetes/ manifests

3. Flux Kustomization Controller processes manifests
   ├─> Loads namespace kustomization.yaml
   ├─> Applies components (namespace, SOPS, etc)
   ├─> Merges overlays
   └─> Generates final manifests

4. Flux Helm Controller applies HelmReleases
   ├─> Fetches helm charts from repos
   ├─> Renders values (interpolation)
   └─> Creates/updates K8s resources

5. Kubernetes reconciles resources
   ├─> Creates Pods, Services, Ingress
   ├─> Mounts Longhorn PVCs
   └─> Exposes via ExternalDNS + Envoy Gateway
```

### Update Flow (Renovate)
```
1. Renovate webhook triggered on schedule
   └─> Scans kubernetes/, bootstrap/, talos/ directories

2. Detects updates (respecting .renovate/ rules)
   ├─> Docker images (security updates prioritized)
   ├─> Helm charts
   ├─> GitHub Actions
   └─> Tool versions

3. Creates PR with changes
   ├─> Groups related updates by .renovate/groups.json5
   ├─> Applies semantic commits (feat:, fix:, chore:)
   └─> Labels based on change type

4. Auto-merge (if configured)
   └─> Creates commit + merges to main

5. Flux re-syncs + deploys
   └─> New versions rolling out to cluster
```

## Directory Patterns

### Namespace Application Pattern
```
kubernetes/apps/my-namespace/
├── kustomization.yaml          # Top-level: namespace + ks.yaml
├── namespace/                  # Optional: namespace-specific resources
│   └── kustomization.yaml
└── my-app/
    ├── app/
    │   ├── kustomization.yaml  # HelmRelease or K8s manifests
    │   ├── helmrelease.yaml
    │   └── values.yaml (optional)
    ├── ks.yaml                 # Flux Kustomization referencing ./app
    └── [overlays or patches]
```

**Flow**:
1. Flux reads `kustomization.yaml` (top-level)
2. Finds `kubernetes/apps/my-namespace/namespace/` component
3. Applies namespace resource + SOPS, alerts, etc
4. Finds `ks.yaml` Flux Kustomization
5. Applies HelmRelease from `my-app/app/kustomization.yaml`
6. Chart deployed with values

### Component Pattern
```
kubernetes/components/my-component/
├── kustomization.yaml
├── component-resource-1.yaml
├── component-resource-2.yaml
├── [overlays or transformations]
└── README.md (optional: usage guide)
```

**Usage**: Referenced in namespace `kustomization.yaml`:
```yaml
components:
  - ../../components/my-component
```

## Security Model

### Secret Management
- **Encryption**: SOPS + age (asymmetric encryption)
- **Key Management**: `age.key` (must be kept secret, synced to cluster)
- **File Pattern**: `*.sops.yaml` (encrypted at rest in Git)
- **Runtime Decryption**: External-secrets operator decrypts for K8s Secrets
- **Renovate Exclusion**: `.renovate/*.json5` excludes `*.sops.*` patterns

### Network Security
- **CNI**: Cilium (enforces network policies)
- **Ingress**: Envoy Gateway filters external traffic
- **External Access**: Cloudflared tunnel (secure, authenticated)
- **Internal DNS**: Private UniFi DNS (not exposed)

### RBAC & Pod Security
- **Namespace Isolation**: Resources confined to namespace (with network policies)
- **Component Defaults**: Labels + annotations applied via namespace component
- **Service Accounts**: Per-application for least privilege
- **Pod Security**: Standards enforced via namespace labels

## Scalability Considerations

### Horizontal Scaling
- **Multiple nodes**: Talos cluster can scale to many nodes
- **Longhorn replication**: Automatic data replication across nodes
- **Stateless workloads**: Auto-scale via HPA (Horizontal Pod Autoscaler)

### Multi-tenancy
- **Multus**: Supports secondary network interfaces for pod networking
- **Namespace isolation**: Separate namespaces for different applications
- **NetworkPolicies**: Restrict traffic between namespaces

### Performance
- **Cilium eBPF**: Lower overhead than iptables-based CNI
- **Spegel**: Local OCI registry mirror (faster image pulls)
- **Longhorn scheduling**: Affinity rules for data locality

## Update & Rollback Strategy

### Normal Updates
1. Renovate creates PR with dependency update
2. PR auto-merges (if low-risk) or awaits approval
3. Flux detects change, reconciles in cluster
4. Health checks monitor new version
5. Auto-rollback if necessary (HelmRelease `remediation`)

### Manual Rollback
```bash
# Revert commit
git revert <commit-sha>
git push

# OR manually edit version in repo
# Flux auto-syncs within reconciliation interval
```

## Disaster Recovery

### Backup Strategy
- **Volsync**: Regular snapshots of persistent volumes
- **GitOps**: Git repo is source of truth (always recoverable)
- **External config**: Secrets backed up separately (outside Git)

### Recovery Procedures
1. **Cluster loss**: Re-bootstrap from `bootstrap/` scripts
2. **Application loss**: Flux restores from Git state
3. **Data loss**: Restore from Volsync snapshots
4. **Config loss**: Git history provides restore points

## Extensibility

### Adding New Applications
1. Create namespace in `kubernetes/apps/`
2. Use namespace component for common setup
3. Add HelmRelease or K8s manifests
4. Renovate automatically monitors for updates

### Adding Reusable Components
1. Create component in `kubernetes/components/`
2. Document usage in README
3. Reference from namespace kustomization.yaml
4. Share across multiple namespaces

### Custom Patches
- Use Kustomize overlays for environment-specific changes
- Use HelmRelease `values:` for Helm customization
- Use strategic merge patches for K8s resource tweaks

## Tools & Ecosystem

| Tool | Purpose | Version |
|------|---------|---------|
| Flux2 | GitOps controller | 2.8.8 |
| Kustomize | K8s manifest generator | 5.8.1 |
| Helm | Package manager | 4.2.0 |
| Renovate | Dependency updater | via GitHub |
| Talos | Immutable OS | 1.13.3 |
| Cilium | Networking | via HelmRelease |
| Longhorn | Storage | via HelmRelease |
| External-secrets | Secret management | via HelmRelease |
| SOPS | Manifest encryption | 3.13.1 |
| Kubeconform | Manifest validation | 0.7.0 |

## Monitoring & Observability

### Metrics & Logging
- **Prometheus**: Scrapes metrics from workloads + nodes
- **Grafana**: Visualizes metrics, dashboards
- **Alertmanager**: Alerts on threshold breaches
- **Logs**: Pod logs accessible via `kubectl logs`

### Troubleshooting
```bash
# Check Flux reconciliation
flux get kustomizations -A
flux logs -f --all-namespaces

# Check HelmRelease status
kubectl get helmrelease -A

# Validate manifests
kustomize build kubernetes/apps/{ns}/ | kubeconform

# SOPS secrets
sops -d kubernetes/apps/{ns}/secret.sops.yaml
```
