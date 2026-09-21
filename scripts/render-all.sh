#!/usr/bin/env bash
#
# render-all.sh — the build this repo does not otherwise have.
#
# Renders EVERY kustomize target in the repo and validates the output against
# the Kubernetes API schemas. Executed by BOTH the `render-validate` pre-commit
# hook and the `render` + `validate` jobs in deploy-pr-opened.yml — one
# implementation, two call sites, so local and CI cannot drift (the structural
# form of lockstep, per IRD-014 and the MIN-60 lesson).
#
# WHY: a service repo fails at `mvn test`; iac-platform fails at `terraform
# plan`. This repo has no compiler. A malformed kustomization.yaml, a values key
# that violates values.schema.json, or a manifest with an invalid API shape
# merges perfectly clean and fails INSIDE THE CLUSTER at sync time — where
# `selfHeal: true` on dev retries it forever. This script is that missing gate.
#
# Exit 0 = every target rendered and validated. Non-zero = at least one failed,
# and every failure is reported (the script does not stop at the first one — you
# want the whole list in one CI run, not one per push).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Where rendered output goes. Caller may override so CI can upload it as an
# artifact for inspection; defaults to a temp dir that is cleaned up.
RENDER_DIR="${RENDER_DIR:-$(mktemp -d)}"
KEEP_RENDER="${KEEP_RENDER:-false}"
# `mktemp -d` creates the directory; a caller-supplied RENDER_DIR does not exist
# yet. Without this the redirect in the render loop fails with "No such file or
# directory" and every target is reported as a RENDER FAILURE — which is exactly
# how the CI `policy` job invokes it (RENDER_DIR=rendered).
mkdir -p "${RENDER_DIR}"
cleanup() {
  if [ "${KEEP_RENDER}" != "true" ]; then
    rm -rf "${RENDER_DIR}"
  fi
}
trap cleanup EXIT

# --- preconditions -----------------------------------------------------------
for tool in kustomize helm kubeconform; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR: ${tool} is not installed. This repo cannot be linted without it." >&2
    echo "       brew install kustomize helm kubeconform" >&2
    exit 127
  fi
done

echo "toolchain: kustomize $(kustomize version) | $(helm version --short) | kubeconform $(kubeconform -v)"
echo

# --- discover every target ---------------------------------------------------
# Every directory holding a kustomization.yaml is a render target. Discovery,
# not a hardcoded list: a new service overlay is covered the moment it exists,
# with no edit here. A hardcoded list is a gate that silently stops covering
# new code — the failure mode this program keeps re-learning.
#
# NOT `mapfile` — TSG-016. macOS ships bash 3.2 (frozen 2007, GPLv2), which has
# no `mapfile`/`readarray`; `#!/usr/bin/env bash` resolves to it on the
# operator's laptop. This script runs in BOTH pre-commit (macOS, bash 3.2) and
# CI (ubuntu, bash 5), so it must target the older one. TSG-016 §Prevention
# names `mapfile` explicitly as a construct to avoid — this is that rule applied.
#
# `-exec dirname {} +` rather than `| xargs -n1 dirname` (SC2038): xargs splits
# on whitespace, so a path containing a space would be torn into two bogus
# targets. `find -exec` passes arguments intact.
TARGETS=()
while IFS= read -r dir; do
  TARGETS+=("${dir}")
done < <(find apps infra -name kustomization.yaml -type f -exec dirname {} + 2>/dev/null | sort -u)

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "ERROR: no kustomization.yaml found under apps/ or infra/." >&2
  echo "       Either the repo layout is wrong or this script's discovery is." >&2
  exit 1
fi

printf 'found %d render target(s)\n\n' "${#TARGETS[@]}"

# --- render + validate -------------------------------------------------------
# kubeconform notes, stated rather than glossed:
#   -strict            rejects unknown fields — catches a typo'd key that would
#                      otherwise be silently ignored by the API server.
#   -summary           per-run counts, so the log says what was actually checked.
#   CRD schemas        ServiceMonitor / ExternalSecret / Kyverno policies are
#                      CRDs; their schemas are NOT in the core catalog. We pull
#                      them from the datreeio CRDs-catalog, and anything still
#                      unresolved is SKIPPED — but the skip is PRINTED, never
#                      silent. A validator that quietly passes what it could not
#                      read is worse than no validator.
CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
K8S_VERSION="${K8S_VERSION:-1.31.0}"

FAILED=()
for target in "${TARGETS[@]}"; do
  out="${RENDER_DIR}/${target//\//_}.yaml"

  printf '==> %s\n' "${target}"

  if ! kustomize build --enable-helm "${target}" >"${out}" 2>"${out}.err"; then
    echo "    RENDER FAILED:"
    sed 's/^/      /' "${out}.err"
    FAILED+=("${target} (render)")
    continue
  fi

  kinds=$(grep -c '^kind:' "${out}" || true)
  printf '    rendered %s object(s)\n' "${kinds}"

  if ! kubeconform \
      -strict \
      -summary \
      -kubernetes-version "${K8S_VERSION}" \
      -schema-location default \
      -schema-location "${CRD_CATALOG}" \
      -ignore-missing-schemas \
      -verbose \
      "${out}" 2>&1 | sed 's/^/    /'; then
    FAILED+=("${target} (validate)")
    continue
  fi
done

echo
if [ ${#FAILED[@]} -ne 0 ]; then
  echo "FAILED (${#FAILED[@]}):" >&2
  printf '  - %s\n' "${FAILED[@]}" >&2
  exit 1
fi

printf 'OK — %d target(s) rendered and validated\n' "${#TARGETS[@]}"
