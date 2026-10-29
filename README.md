# Ascender Operator

[![ascender-operator CI](https://img.shields.io/github/actions/workflow/status/ctrliq/ascender-operator/devel.yaml?branch=devel&label=ascender-operator%20CI)](https://github.com/ctrliq/ascender-operator/actions/workflows/devel.yaml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Operator SDK](https://img.shields.io/badge/built%20with-Operator%20SDK-blue.svg)](https://github.com/operator-framework/operator-sdk)

A Kubernetes operator that deploys and manages [Ascender](https://github.com/ctrliq/ascender), built with the [Operator SDK](https://github.com/operator-framework/operator-sdk) and Ansible. It reconciles Ascender deployments, their backups and restores, and automation mesh ingress, from custom resources you apply.

## Requirements

- A Kubernetes cluster, and `kubectl` configured to reach it
- `helm`, if installing from the chart
- `make`, `nox`, and `molecule`, for development and testing

## Installation

Most users should not install this directly. The [Ascender installer](https://github.com/ctrliq/ascender-install) deploys it as part of a normal install.

To deploy it on its own:

```bash
make deploy
```

## Using the operator

Apply a custom resource describing the deployment you want, then let the operator reconcile it:

```bash
kubectl apply -f ascender-demo.yml
```

An automation mesh ingress is declared the same way, using [`ascendermeshingress-demo.yml`](./ascendermeshingress-demo.yml) as the starting point.

## Configuration

Deployment options are set as fields on the custom resource rather than as operator settings. The `config/` directory holds the CRDs, RBAC, and manager manifests, and `.helm/starter` holds the chart used for Helm-based installs.

## Included content

The operator watches four custom resource kinds in the `awx.ansible.com` group:

- **`AWX`**: the Ascender deployment itself, reconciled by the `installer` role
- **`AWXBackup`**: backup of an existing deployment, including its database
- **`AWXRestore`**: restore of a deployment from a previously taken backup
- **`AWXMeshIngress`**: ingress configuration for Ascender automation mesh

## Testing

Molecule drives the operator test suite, orchestrated through nox.

- **Full suite**: `nox`
- **Molecule directly**: `molecule test`

Smoke tests also run automatically as part of the release workflows, so there is no need to trigger them by hand.

## Release process

Releases normally happen through the Stage Release workflow, which runs smoke tests before publishing.

- The workflow creates a draft release, usually triggered from the Ascender release
- Publishing the draft runs the promote workflow, which pushes the image and chart
- To release the operator independently, run Stage Release in this repository

## The Ascender ecosystem

| Repository | Description |
| ---------- | ----------- |
| [ascender](https://github.com/ctrliq/ascender) | The platform itself: web UI, REST API, and task engine |
| [ascender-install](https://github.com/ctrliq/ascender-install) | Installer for Ascender and Ledger, with Galaxy Proxy support |
| [ascender-k8s-install](https://github.com/ctrliq/ascender-k8s-install) | Kubernetes installer for Ascender, Ledger, and React |
| [ascender-pro-install](https://github.com/ctrliq/ascender-pro-install) | Enhanced installer adding Reaqt, Registry, and Galaxy Proxy |
| [ascender-operator](https://github.com/ctrliq/ascender-operator) | Kubernetes operator that deploys and manages Ascender |
| [ascender-ee](https://github.com/ctrliq/ascender-ee) | Default execution environment image for Ascender jobs |
| [ascender-kit](https://github.com/ctrliq/ascender-kit) | The `ascender` command line client and Python API library |
| [ascender-collection](https://github.com/ctrliq/ascender-collection) | The `ctrliq.ascender` Ansible collection for a controller |
| [ascender-mcp](https://github.com/ctrliq/ascender-mcp) | MCP server that lets AI agents drive Ascender through its REST API |
| [ascender-ledger](https://github.com/ctrliq/ascender-ledger) | Reporting tool for host facts and playbook changes |
| [ascender-galaxy-proxy](https://github.com/ctrliq/ascender-galaxy-proxy) | Caching proxy for Ansible Galaxy collection downloads |
| [ascender-playbooks](https://github.com/ctrliq/ascender-playbooks) | Example playbooks for use with Ascender |
## Contributing

- See [CONTRIBUTING.md](./CONTRIBUTING.md) for development setup, testing, and pull requests.
- Target the `devel` branch, which is this repository's default and its CI branch.
- Report bugs and feature ideas via [GitHub Issues](https://github.com/ctrliq/ascender-operator/issues).
- For security vulnerabilities, follow [SECURITY.md](./SECURITY.md) rather than opening an issue.
- Join the [Ascender forum](https://forum.ascender-automation.org) to discuss development topics.

## License

Licensed under the **Apache License 2.0**. See [LICENSE](./LICENSE) for the full text.

Originally built in 2019 by [Jeff Geerling](https://www.jeffgeerling.com) as the AWX Operator, and maintained for Ascender by Ctrl IQ.
