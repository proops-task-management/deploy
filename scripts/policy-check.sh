#!/usr/bin/env bash
#
# policy-check.sh — run the cluster's own Kyverno policies against every
# rendered manifest set.
#
# Executed by BOTH the `policy` job in deploy-pr-opened.yml AND `task policy`.
# One implementation, two call sites — the same rule render-all.sh follows, and
# the rule this repo has now been taught twice in one day (a duplicated CI
# install block drifted and broke `policy`; the Taskfile carried a third copy of
# this very command).
#
# WHY PER-TARGET AND NOT ONE `kyverno apply rendered/`:
#
#   panic: services "frontend-service" already exists
#
# That is what the whole-directory form does here, and it is not a kyverno bug.
# `rendered/` holds base + dev + staging + prod, i.e. FOUR copies of
# Service/Deployment/PDB named `frontend-service` — and none of them carries
# `metadata.namespace`, because charts/app deliberately does not emit it (Helm
# convention; Argo CD's destination.namespace places them — see any overlay's
# kustomization.yaml). So kyverno's fake client sees four resources with the
# same namespace+kind+name and panics on the duplicate.
#
# Validating them together is semantically wrong anyway: each overlay is an
# INDEPENDENT Argo Application targeting its own namespace. They never coexist
# in one namespace in the real cluster, so they must not be loaded into one
# fake client here. Per-target matches reality and removes the collision by
# construction rather than by deduplication.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

POLICY_DIR="${POLICY_DIR:-infra/kyverno/policies}"
RENDER_DIR="${RENDER_DIR:-rendered}"

if ! command -v kyverno >/dev/null 2>&1; then
  echo "ERROR: kyverno is not installed." >&2
  echo "       brew install kyverno" >&2
  exit 127
fi

# A policy job with no policies passes every manifest trivially. Fail loudly
# rather than report a green gate that checks nothing.
if [ -z "$(find "${POLICY_DIR}" -name '*.yaml' -type f 2>/dev/null)" ]; then
  echo "ERROR: no policies found in ${POLICY_DIR}/." >&2
  echo "       An empty policy set means every manifest trivially complies." >&2
  exit 1
fi

# Render if the caller has not already done so.
if [ ! -d "${RENDER_DIR}" ]; then
  RENDER_DIR="${RENDER_DIR}" KEEP_RENDER=true ./scripts/render-all.sh >/dev/null
fi

FAILED=()
TOTAL_PASS=0
TOTAL_FAIL=0

while IFS= read -r manifest; do
  printf '==> %s\n' "${manifest}"

  # TWO invocations on purpose, and the flags differ for a reason found the hard
  # way: `--table` SUPPRESSES the `pass: N, fail: N, ...` summary line. Parsing
  # counts out of the table run therefore yields nothing, which tripped this
  # script's own zero-match guard on its first execution. So:
  #   - no `--table`  -> machine-readable summary + the exit status that matters
  #   - with `--table` -> the human-readable grid printed into the log
  #
  # `|| status=$?` rather than letting `set -e` abort: one failing target must
  # not hide the others. The whole list of violations in one run is worth more
  # than the first one.
  status=0
  summary_out="$(kyverno apply "${POLICY_DIR}/" --resource "${manifest}" --detailed-results 2>&1)" || status=$?
  table_out="$(kyverno apply "${POLICY_DIR}/" --resource "${manifest}" --detailed-results --table 2>&1 || true)"

  # Deprecation warnings are noise here; they are tracked on their own ticket.
  printf '%s\n' "${table_out}" | grep -v 'is deprecated and will be removed' | sed 's/^/    /'

  # Accumulate the reported counts so the run can prove it evaluated something.
  line="$(printf '%s\n' "${summary_out}" | grep -E '^pass: ' || true)"
  if [ -n "${line}" ]; then
    p="$(printf '%s\n' "${line}" | sed -E 's/.*pass: ([0-9]+).*/\1/')"
    f="$(printf '%s\n' "${line}" | sed -E 's/.*fail: ([0-9]+).*/\1/')"
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
  fi

  if [ "${status}" -ne 0 ]; then
    FAILED+=("${manifest}")
  fi
done < <(find "${RENDER_DIR}" -name '*.yaml' -type f 2>/dev/null | sort)

echo
printf 'evaluated: %d pass, %d fail across all targets\n' "${TOTAL_PASS}" "${TOTAL_FAIL}"

# The second vacuous-pass guard. Policies exist and targets rendered, but if
# NOTHING was actually evaluated — every policy matched zero resources, e.g.
# after a kind/matcher change — the gate is green while checking nothing. That
# is the exact failure mode this repo keeps filing tickets about.
if [ "$((TOTAL_PASS + TOTAL_FAIL))" -eq 0 ]; then
  echo "ERROR: policies matched ZERO resources across every target." >&2
  echo "       The gate would be green while checking nothing. Verify the policies' match blocks." >&2
  exit 1
fi

if [ ${#FAILED[@]} -ne 0 ]; then
  echo
  echo "POLICY VIOLATIONS in ${#FAILED[@]} target(s):" >&2
  printf '  - %s\n' "${FAILED[@]}" >&2
  exit 1
fi

echo "OK — all targets policy-clean"
