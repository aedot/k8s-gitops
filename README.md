## TODO: FIX READme
<div align="center">
  <img src="https://raw.githubusercontent.com/aedot/agemo-ops/main/docs/assets/logo.png" align="center" width="144px" height="144px"/>
  <h3> My home operations repository </h3>
  <i>managed with Flux, Renovate and GitHub Actions</i> 🤖
</div>

<div align="center">

<div>

[![Talos](https://img.shields.io/badge/1.9.3-orange?style=for-the-badge&logo=talos&logoColor=white)](https://talos.dev  "Talos OS")
[![Kubernetes](https://img.shields.io/badge/1.32-blue?style=for-the-badge&logo=kubernetes&logoColor=white)](https://kubernetes.io)
[![Flux](https://img.shields.io/badge/2.4.0-blue?style=for-the-badge&logo=flux&logoColor=white)](https://fluxcd.io)

</div>
</div>

## 📖 Overview

This is a monorepo for my homelab infrastructure automation deploy with [Talos](https://www.talos.dev). I try to adhere (as much as I reasonably can 😅) to Infrastructure as Code (IaC) and GitOps practices using the tools like `Kubernetes`, `FluxCD`, `Renovate` and `GitHub Actions`.

### Directories

This Git repository contains the following directories under [Kubernetes](./kubernetes/).

```sh
📁 kubernetes
├── 📁 apps            # applications
├── 📁 bootstrap       # bootstrap procedures
├── 📁 flux            # core flux configuration
├── 📁 components      # re-useable components
└── 📁 ...             # other clusters
📁 templates
```

## 💥 Reset

There might be a situation where you want to destroy your Kubernetes cluster. The following command will reset your nodes back to maintenance mode, append `--force` to completely format your the Talos installation. Either way the nodes should reboot after the command has sucessfully ran.

```sh
task talos:reset # --force
```

## 🛠️ Talos and Kubernetes Maintenance

### ⚙️ Updating Talos node configuration

> [!IMPORTANT]
> Ensure you have updated `talconfig.yaml` and any patches with your updated configuration. In some cases you **not only need to apply the configuration but also upgrade talos** to apply new configuration.

```sh
# (Re)generate the Talos config
task talos:generate-config
# Apply the config to the node
task talos:apply-node IP=? MODE=?
# e.g. task talos:apply-node IP=10.10.10.10 MODE=auto
```

### ⬆️ Updating Talos and Kubernetes versions

> [!IMPORTANT]
> Ensure the `talosVersion` and `kubernetesVersion` in `talconfig.yaml` are up-to-date with the version you wish to upgrade to.

```sh
# Upgrade node to a newer Talos version
task talos:upgrade-node IP=?
# e.g. task talos:upgrade-node IP=10.10.10.10
```

```sh
# Upgrade cluster to a newer Kubernetes version
task talos:upgrade-k8s
# e.g. task talos:upgrade-k8s
```


## 🤝 Gratitude and Thanks

There is a template over at [onedr0p/flux-cluster-template](https://github.com/onedr0p/flux-cluster-template).

Thanks to all the people who donate their time to the [Kubernetes @Home](https://discord.gg/k8s-at-home) Discord community. A lot of inspiration for my cluster comes from the people that have shared their clusters using the [k8s-at-home](https://github.com/topics/k8s-at-home) GitHub topic. Be sure to check out the [Kubernetes @Home search](https://nanne.dev/k8s-at-home-search/) for ideas on how to deploy applications or get ideas on what you can deploy.
