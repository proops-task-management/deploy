# deploy — the single source of truth for what runs where

Argo CD watches **only this repo**. Any manual change made directly to the cluster is drift and
will be reverted by self-heal. Governed by
[IRD-017](https://github.com/proops-task-management/docs/blob/main/irds/platform/IRD-017-gitops-deploy-platform.md).

> This repo is **public git on purpose** — Argo CD then needs no repository credential
> (IRD-017 §Bootstrap). It is public *git*; the container registry it references stays
> **private** (ADR-013). Because it is public, a committed secret is scraped within minutes,
> which is why `secret-scan.yml` runs on every PR with **no path filter**.

## The tool split (locked — IRD-017 Decision 3)

| Tool | Owns | Does **not** own |
|---|---|---|
| **Helm** | the *shape* — one `app` chart for all 5 services | per-environment difference |
| **Kustomize** | per-env difference; inflates the chart via `helmCharts:` + `--enable-helm` | **ordering** |
| **Argo CD** | delivery **and ordering** (sync waves `-3 → 1`) | authoring manifests |

Getting this boundary wrong is the most common way a GitOps repo rots. Kustomize has no concept
of "apply this before that"; if something must come first, it is a **sync wave**, not a patch.

## Layout

```
bootstrap/        app-of-apps root — the one thing pointed at by hand, once per cluster
charts/app/       the shared chart every service uses (one template, five values files)
apps/<service>/   base/ (chart + values-common) + overlays/{dev,staging,prod}
infra/            third-party components, pinned chart versions, one dir each
argocd/           ApplicationSet (5 services × 3 envs) + one Application per infra component
scripts/          render-all.sh — run by BOTH pre-commit and CI
```

## Getting started

```bash
brew install go-task helm kustomize kubeconform   # kyverno optional, for `task policy`
task hooks        # once per clone — until you run this, your commits are NOT linted
task lint         # everything the CI gate runs
```

## The one thing to understand about CI here

**This repo has no compiler.** A service repo fails at `mvn test`; `iac-platform` fails at
`terraform plan`. Here, a malformed `kustomization.yaml`, a values key that violates the schema,
or a manifest that breaks a Kyverno policy will **merge perfectly clean** and fail *inside the
cluster* at sync time — where `selfHeal: true` on `dev` retries the broken state indefinitely.

So the render **is** the build. `deploy-pr-opened.yml` gives four signals, ordered by how cheaply
they find a defect:

| Job | Question it answers | Tool |
|---|---|---|
| `chart-lint` | Is the chart itself well-formed? | `helm lint` |
| `render` | Does every overlay produce valid Kubernetes YAML? | `kustomize` + `kubeconform` |
| `policy` | Would the cluster's admission control accept it? | `kyverno` CLI |
| `workflow-lint` | Are these workflows themselves valid? | `actionlint` + `yamllint` |

`policy` runs **this repo's own** `infra/kyverno/policies/` — the exact files Argo CD installs
into the cluster, not a private copy. That identity is the point: a gate testing its own copy of
the rules would drift from what admission actually enforces, and the drift would surface only as
a rejected sync.

`render` and `policy` both execute `scripts/render-all.sh`, the same script the `render-validate`
pre-commit hook runs. One implementation, three call sites — local and CI cannot disagree about
*what* is rendered or *how* it is validated.

## Flows

- **Ship** — merge in a service repo → CI builds `:sha` → CI commits `kustomize edit set image`
  in `overlays/dev` → Argo syncs dev within ~5 min.
- **Promote** — a human PR *in this repo* copying the SHA `dev → staging → prod`. The diff is
  exactly one image line per service. **The PR review is the gate**, not a manual Sync click.
- **Rollback** — `git revert` the bump commit. Target ≤ 5 min.
- **Verify** — `kustomize build overlays/prod | grep image:` equals what is actually running.

Nobody ever runs `kubectl set image`. There is no step in any of these flows where a human
touches the cluster.

## Conventions

Branches and commits follow
[IRD-025](https://github.com/proops-task-management/docs/blob/main/irds/platform/IRD-025-git-workflow-conventions.md):
branch `<type>/minh_dt/<short-description>`, commit `<type>(<scope>): <subject>`. The scope for
work in this repo is `deploy`.
