#!/usr/bin/env bash
#
# appset-eval.sh — evaluate the ApplicationSet with the cluster's OWN controller (MIN-79).
#
# WHY THIS EXISTS: every other signal in deploy-pr-opened.yml validates the
# ApplicationSet as a YAML OBJECT — and it is valid YAML whatever its template
# renders to. At D12 (TSG-035) `spec.goTemplate` was unset while the template
# used `{{.service}}`, so the default fasttemplate engine substituted nothing and
# all 15 Applications were named the literal `{{.service}}-{{.env}}`. CI was
# green. The defect was visible only once a real ApplicationSet controller
# evaluated it — on a metered cluster.
#
# So this script runs THAT controller, not a model of it:
#   1. a throwaway kind cluster (isolated kubeconfig — never the operator's)
#   2. the Argo CD chart at the SAME version the cluster runs (lockstep-checked
#      against iac-platform below), with the application-controller scaled to 0
#      — Applications are GENERATED but never SYNCED, so nothing is deployed
#   3. apply argocd/applicationset-services.yaml, poll its status (ADR-016)
#   4. assert: no ErrorOccurred · exactly EXPECTED_APPS Applications · every
#      name a valid RFC 1123 label · then delete the cluster
#
# WHY NOT RE-IMPLEMENT THE RENDERING (yq + Go template): that would be a private
# copy of Argo's logic — the exact "CI tests a copy of the rules" drift this repo
# refuses for Kyverno (policy-check.sh runs the cluster's own policy files). It
# would also have to model the fasttemplate/goTemplate engine choice, which is
# precisely where TSG-035 came from.
#
# WHY THE NAME CHECK IS AN RFC 1123 *LABEL* (≤63, no dots), NOT a subdomain
# (≤253): the API server already rejects a non-subdomain name, so checking that
# again would test Kubernetes, not us. The stricter constraint is Argo's own —
# the Application name becomes the `app.kubernetes.io/instance` tracking-label
# VALUE, which must be a 63-char label. A 70-char name is accepted by the API
# server and then breaks resource tracking on the cluster. That is the check
# worth having.
#
# CALL SITES — one implementation, two callers (the render-all.sh pattern):
#   CI    : deploy-pr-opened.yml job `appset-eval` (pins from its env block)
#   local : `task appset` (needs Docker + kind + kubectl + helm on PATH)
# NOT a pre-commit hook: ~2 min and a container runtime per commit is the wrong
# trade; the CI job is the enforced gate.
#
# Pins are read from the environment, or — when unset (local run) — parsed from
# deploy-pr-opened.yml's `env:` block, so the workflow stays the SINGLE place a
# version is written. This script never becomes a second source of truth.
set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOW=".github/workflows/deploy-pr-opened.yml"
APPSET_FILE="argocd/applicationset-services.yaml"
APPSET_NAME="services"
ARGOCD_NS="platform"            # same namespace as the cluster (IRD-017 §Bootstrap)
CLUSTER_NAME="appset-eval"
EXPECTED_APPS="${EXPECTED_APPS:-15}"   # 5 services × 3 envs; a 6th service bumps this deliberately
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-180}"
POLL_INTERVAL_S=5

die() { echo "ERROR: $*" >&2; exit 1; }

# pin NAME → value from env, else from the workflow's env block (two-space indent, quoted).
pin() {
  local name="$1" val="${!1:-}"
  if [[ -z "${val}" ]]; then
    val="$(sed -n "s/^  ${name}: \"\([^\"]*\)\".*/\1/p" "${WORKFLOW}")"
  fi
  [[ -n "${val}" ]] || die "${name} is not set and was not found in ${WORKFLOW}'s env block"
  printf '%s' "${val}"
}

for tool in docker kind kubectl helm curl; do
  command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not installed (needed to run the real ApplicationSet controller)"
done

ARGOCD_CHART_VERSION="$(pin ARGOCD_CHART_VERSION)"
KIND_NODE_IMAGE="$(pin KIND_NODE_IMAGE)"
IAC_PLATFORM_PINS_URL="$(pin IAC_PLATFORM_PINS_URL)"

# ---------------------------------------------------------------------------
# 1. LOCKSTEP — fail fast, before spending two minutes on a cluster.
# An evaluator on a different controller version than the cluster proves
# nothing about the cluster. iac-platform is public, so this is checked, not
# commented. An unreachable source is a FAILURE, not a skip: "could not verify"
# is not "verified".
# ---------------------------------------------------------------------------
echo "== lockstep: Argo CD chart pinned here vs. what the cluster installs =="
cluster_pin="$(curl -fsSL --retry 3 --retry-connrefused "${IAC_PLATFORM_PINS_URL}" \
  | sed -n 's/^argocd_chart_version:[[:space:]]*"\([^"]*\)".*/\1/p')" \
  || die "could not fetch ${IAC_PLATFORM_PINS_URL} — lockstep cannot be verified"
[[ -n "${cluster_pin}" ]] || die "argocd_chart_version not found in ${IAC_PLATFORM_PINS_URL}"
if [[ "${cluster_pin}" != "${ARGOCD_CHART_VERSION}" ]]; then
  die "Argo CD chart drift: this gate evaluates with ${ARGOCD_CHART_VERSION}, the cluster installs ${cluster_pin} (iac-platform). Bump ARGOCD_CHART_VERSION in ${WORKFLOW} to match — a green result on another controller version says nothing about the cluster."
fi
echo "ok — both pin argo-cd chart ${ARGOCD_CHART_VERSION}"

# ---------------------------------------------------------------------------
# 2. Throwaway cluster, ISOLATED kubeconfig. Every kubectl/helm call below gets
# this file explicitly, so the operator's current context (possibly the real
# k3s cluster) is never read, never written, never targeted.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
export KUBECONFIG="${WORK}/kubeconfig"
cleanup() {
  kind delete cluster --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# Idempotent: a previous aborted local run may have left the cluster behind.
# Output captured FIRST, then matched — NOT `kind get clusters | grep -q`: grep -q
# exits on the first match, the producer can take SIGPIPE, and pipefail turns a
# successful check into exit 141 with no message (TSG-031).
existing="$(kind get clusters 2>/dev/null || true)"
if grep -qx "${CLUSTER_NAME}" <<<"${existing}"; then
  echo "== removing a leftover '${CLUSTER_NAME}' cluster from an earlier run =="
  kind delete cluster --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG}"
fi

echo "== kind cluster (${KIND_NODE_IMAGE%@*}) =="
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" \
  --kubeconfig "${KUBECONFIG}" --wait 120s

# ---------------------------------------------------------------------------
# 3. Argo CD at the cluster's version. application-controller = 0: it is the
# component that SYNCS, and nothing here may be synced — we want the generated
# Application objects, not workloads. dex/notifications are irrelevant to
# generation. --wait makes helm block on readiness (no guessed sleep).
# ---------------------------------------------------------------------------
echo "== argo-cd chart ${ARGOCD_CHART_VERSION} (application-controller scaled to 0) =="
helm install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "${ARGOCD_CHART_VERSION}" \
  --namespace "${ARGOCD_NS}" --create-namespace \
  --set controller.replicas=0 \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --wait --timeout 5m

# The generated Applications reference `project: default`, which Argo CD
# creates at startup — the ApplicationSet controller rejects an Application
# whose project does not exist. Poll for it rather than assume it (ADR-016).
poll() {  # poll <description> <command...> — true when the command succeeds
  local what="$1"; shift
  local deadline=$(( SECONDS + POLL_TIMEOUT_S ))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep "${POLL_INTERVAL_S}"
  done
  echo "ok — ${what}"
}
poll "AppProject 'default' exists" \
  kubectl get appproject default -n "${ARGOCD_NS}" \
  || die "AppProject 'default' never appeared within ${POLL_TIMEOUT_S}s — Argo CD did not finish starting"

# ---------------------------------------------------------------------------
# 4. Apply the REAL file and let the REAL controller evaluate it.
# ---------------------------------------------------------------------------
echo "== apply ${APPSET_FILE} =="
kubectl apply -n "${ARGOCD_NS}" -f "${APPSET_FILE}"

cond() {  # cond <type> → that condition's status ("True"/"False"/"")
  kubectl get applicationset "${APPSET_NAME}" -n "${ARGOCD_NS}" \
    -o jsonpath="{.status.conditions[?(@.type==\"$1\")].status}"
}
show_conditions() {
  echo "--- ApplicationSet '${APPSET_NAME}' status.conditions ---" >&2
  kubectl get applicationset "${APPSET_NAME}" -n "${ARGOCD_NS}" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}' >&2 || true
}

# Settled = the controller has reached a verdict either way.
settled() { [[ "$(cond ResourcesUpToDate)" == "True" || "$(cond ErrorOccurred)" == "True" ]]; }
if ! poll "controller reached a verdict" settled; then
  show_conditions
  die "ApplicationSet did not settle within ${POLL_TIMEOUT_S}s"
fi

# ---------------------------------------------------------------------------
# 5. Assertions. Each failure prints the controller's own words first — the
# diagnosis TSG-035 had to dig out by hand on a running meter.
# ---------------------------------------------------------------------------
fail=0

if [[ "$(cond ErrorOccurred)" == "True" ]]; then
  show_conditions
  echo "FAIL: the ApplicationSet controller reported ErrorOccurred — the template does not render to valid Applications" >&2
  fail=1
fi

names="$(kubectl get applications.argoproj.io -n "${ARGOCD_NS}" \
  -o jsonpath="{range .items[?(@.metadata.ownerReferences[0].name==\"${APPSET_NAME}\")]}{.metadata.name}{\"\\n\"}{end}")"
count="$(grep -c . <<<"${names}" || true)"

echo "== generated Applications: ${count} (expected ${EXPECTED_APPS}) =="
[[ -n "${names}" ]] && sed 's/^/  /' <<<"${names}"

if [[ "${count}" -ne "${EXPECTED_APPS}" ]]; then
  echo "FAIL: generated ${count} Applications, expected ${EXPECTED_APPS} — under/over-generation is the same class of silence as a bad name" >&2
  fail=1
fi

while IFS= read -r n; do
  [[ -z "${n}" ]] && continue
  if (( ${#n} > 63 )) || ! [[ "${n}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "FAIL: '${n}' is not a valid RFC 1123 label (≤63 chars, [a-z0-9-], alnum at both ends) — Argo uses it as the app.kubernetes.io/instance label value" >&2
    fail=1
  fi
done <<<"${names}"

if (( fail )); then
  echo "appset-eval: RED" >&2
  exit 1
fi
echo "appset-eval: GREEN — ${count} Applications, all names valid, no controller errors (argo-cd chart ${ARGOCD_CHART_VERSION})"
