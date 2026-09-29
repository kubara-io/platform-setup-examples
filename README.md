# kubara platform setup examples

Reference architectures, setup patterns, and runnable lab environments for [kubara](https://docs.kubara.io/) users.

kubara manages Kubernetes platform foundations through GitOps, catalog composition, and Argo CD. Some production architectures and workload topologies require custom layout patterns, advanced Argo CD extensions, or multi-cluster configurations that go beyond core documentation guides. This repository collects patterns and experiments demonstrating how to solve those scenarios.

> [!WARNING]
> Setups in this repository are references and learning resources, not production-hardened configurations. Review, adapt, and harden security controls, credentials, and network policies before using them in live environments.

## Examples catalog

| Example | Type | Featured tools & components | Demo goal |
|---|---|---|---|
| [`argo-cd-agents`](./argo-cd-agents/) | Runnable Lab | Argo CD Agent, vCluster, kind, cert-manager, External Secrets | Managed-mode hub-and-spoke setup with isolated application controllers on spoke clusters reporting status back to the hub. |
| [`sveltos-cluster-management`](./sveltos-cluster-management/) | Architecture Pattern | Project Sveltos, kro, vCluster, custom catalog | Scalable multi-cluster fleet management using Project Sveltos instead of central Argo CD for cluster add-ons and configurations. |

## Example types

Every example falls into one of two categories:

- **Runnable Lab**: A hands-on environment with automated bootstrap scripts, local clusters (such as kind or vCluster), and verification checks. Includes teardown steps.
- **Architecture Pattern**: Static reference manifests and directory structures that illustrate a design pattern (such as AppProject layouts or custom Kustomize overlays) without requiring a running cluster.

## Contributing an example

To add an example to this repository:

1. Create a top-level directory named using kebab-case: `my-example-name/`.
2. Copy `_template/README.md` into your new directory as its starting point.
3. Complete all required sections in your example `README.md`, including a Mermaid diagram, requirements, and walkthrough steps.
4. Add your entry to the [Examples catalog](#examples-catalog) table above, noting the directory link, example type, additional tools used, and demo goal.
