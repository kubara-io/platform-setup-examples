# Agent instructions

This repository stores reference setups and architecture patterns for kubara users. When creating or modifying examples in this repository, follow these standards.

## Purpose of this repository

kubara users need concrete examples for complex setups, custom workload patterns, or architectural topologies that documentation alone cannot fully address (for example: app-of-apps patterns, Kustomize layouts, multi-cluster agent architectures).

Examples are references and learning setups. They are not guaranteed to be production-ready configurations.

## Example types

Every example falls into one of two categories:

1. **Architecture Pattern**: Static reference manifests and directory structures illustrating a design pattern (for example, AppProject layouts, app-of-apps setups, or custom Kustomize overlays). No live cluster lifecycle required. Focuses on explaining the concepts, highlighting key configuration points, and providing next-step links.
2. **Runnable Lab**: A hands-on environment with automated bootstrap scripts, local clusters (such as kind or vCluster), verification tests, and clean-up instructions.

## Directory structure rules

- Put every example in its own top-level directory using kebab-case (for example: `argo-cd-agents`, `app-of-apps`).
- Do not modify or put non-template content into `_template/`.
- Every example directory must contain its own self-contained `README.md`.
- Copy `_template/README.md` as the starting point and adapt it to match the example type.

## Example README requirements

Each example `README.md` must include:

1. **Warning callout**: Explicit notice that the example is a reference pattern and not production-hardened.
2. **Purpose**: Specific problem, scenario, or architecture demonstrated.
3. **Architecture diagram**: At least one Mermaid (`mermaid`) diagram depicting topology, components, or directory flow.
4. **Type and prerequisites**: Categorization (`Architecture Pattern` or `Runnable Lab`), plus either context/prerequisites or a requirements table.
5. **Structure**: File layout tree explaining key artifacts.
6. **Walkthrough / Instructions**:
   - For **Architecture Pattern**: A conceptual walkthrough, key configuration points, adoption notes, and a "Where to go from here" section with relevant documentation links.
   - For **Runnable Lab**: Step-by-step bootstrap and verification instructions, followed by a "Clean up" section.

## Repository catalog update

Whenever you add or rename an example:

1. Update the table in root `README.md` with:
   - Example directory name and link
   - Type (`Architecture Pattern` or `Runnable Lab`)
   - Featured tools and components beyond kubara defaults
   - Demo goal summary
2. Keep the table alphabetically sorted or logically grouped.

## Writing style rules

- Use sentence case for headings.
- Avoid promotional fluff and artificial enthusiasm. State what the setup does, what tools it uses, and how to inspect or run it.
- Keep diagrams simple and focused on the components specific to the example.
