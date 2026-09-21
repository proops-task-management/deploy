# deploy repo — agent instructions

GitOps source of truth. Argo CD watches only this repo. Governed by **IRD-017**; security gates by
**IRD-021**; secrets by **IRD-019**; branch/commit conventions by **IRD-025** (scope: `deploy`).

Read `README.md` first — it carries the tool split and the flows. This file is the part an agent
gets wrong without being told.

## The rule that overrides intuition here

**Never apply anything to a cluster from this repo.** No `kubectl apply`, no `helm install`, no
`argocd app sync`. The only path from a manifest to the cluster is a merge to `main`. If you find
yourself reaching for a cluster command to "just test it", the correct move is `task render` or
`task policy` locally. Argo's `selfHeal` would revert a manual change anyway, minutes later, with
no obvious link back to what you did.

## Tool boundaries — do not blur these

- **Helm = shape.** One chart, `charts/app`, for all five services. A per-service difference goes
  in that service's values file, not in a new chart.
- **Kustomize = per-env difference only.** It inflates the chart. It does **not** express ordering.
- **Argo CD = delivery and ordering.** If something must happen before something else, that is a
  **sync wave** (`-3 → 1`, table in IRD-017), never a Kustomize trick.

`charts/app/Chart.yaml` is `type: application`, **not** `type: library`, despite IRD-017's prose
calling it "the app library chart". A Helm `library` chart cannot be rendered, and
`kustomize build --enable-helm` requires a renderable chart. "Library" there means "the one shared
chart".

## Pod security is hardcoded, and that is deliberate

`charts/app/templates/deployment.yaml` sets `runAsNonRoot`, `drop: [ALL]`, `seccompProfile:
RuntimeDefault`, `allowPrivilegeEscalation: false` and `readOnlyRootFilesystem` **in the template**,
not in `values.yaml`. This is so no values file can weaken them and so output passes Kyverno by
construction.

**Do not "fix" a failing workload by making these values-driven.** If an image cannot run under
them, the image is what changes — that is the whole content of MIN-38 (frontend nginx runs as
root and will not start under this chart). `readOnlyRootFilesystem` additionally means anything
that writes at runtime needs an explicit `emptyDir`; today only `/tmp` is mounted, which suits a
JVM and not nginx.

## Before you change a chart template

A `charts/app` change affects **all five services at once**. `Chart.yaml`'s `version` is therefore
a platform-wide rollout marker — bump it deliberately, never as a side effect. Always run
`task render` afterwards: it re-renders every overlay, not just the one you were thinking about.

## Adding a service

1. `apps/<service>/base/` — `kustomization.yaml` (`helmCharts:` → `../../../charts`) +
   `values-common.yaml`, validated against `charts/app/values.schema.json`.
2. `apps/<service>/overlays/{dev,staging,prod}/` — namespace, `images:` (immutable SHA), replicas.
3. Register it in `argocd/applicationset-services.yaml`.
4. `task render` — the new target is discovered automatically; `scripts/render-all.sh` finds every
   `kustomization.yaml` rather than reading a list.

## Image tags

Never `latest`, never a floating tag. The overlay's `images:` transformer sets an immutable SHA
that CI pushed. This is enforced three times over: `values.schema.json` rejects it at render,
`disallow-latest-tag` rejects it at admission, and `helm template` fails on an empty tag. If you
are tempted to write a tag by hand in `values-common.yaml`, you are probably editing the wrong
file — the overlay is where tags live.

## Secrets

This repo holds **ExternalSecret CRs only** — references, never values. Real secrets are
materialized into the cluster by ESO from AWS SSM (IRD-019). The repo is **public git**, so a
committed credential is scraped within minutes. `gitleaks` runs unfiltered on every PR; do not
add a `.gitleaks.toml` allowlist (TSG-010: fix the source, never broaden the rule).

## Kyverno policies live here and are dual-purpose

`infra/kyverno/policies/` is both what Argo installs into the cluster **and** what the CI `policy`
job checks PRs against. Keep it that way — a separate copy for CI would drift from what admission
enforces. They are `validationFailureAction: Audit` until **D17**, when they flip to `Enforce`;
`kyverno apply` in CI reports violations regardless, so the PR gate is strict even while the
cluster is only observing.

## Troubleshooting note

Render errors are unusually bad at naming their own cause: a values-schema violation reports
`Must not validate the schema (not)`, points at a deleted temp file rather than the real
`values-common.yaml`, and ends with a misleading `(is 'helm' installed?)`. Read the *first* line,
not the last, and check the values file the target actually uses.
