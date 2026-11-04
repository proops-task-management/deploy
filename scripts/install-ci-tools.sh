#!/usr/bin/env bash
#
# install-ci-tools.sh — the CI toolchain, installed once, defined once.
#
# WHY THIS EXISTS: the `render` and `policy` jobs both run scripts/render-all.sh,
# so both need helm + kustomize + kubeconform; `policy` additionally needs
# kyverno. The first version of deploy-pr-opened.yml duplicated the install
# block in both jobs and they immediately drifted — `policy`'s copy omitted
# kubeconform, and the job died with exit 127 on the very first PR:
#
#   ERROR: kubeconform is not installed. This repo cannot be linted without it.
#
# That is the same defect class this repo already solved twice by sharing one
# file instead of two copies (render-all.sh across hook and CI; lint-brace-guard.sh
# in iac-platform). GitHub Actions has no YAML anchors, so "don't repeat the
# block" has to mean "put the block in a script".
#
# ALL TOOLS ARE INSTALLED UNCONDITIONALLY, including kyverno in the `render` job
# and kind/kubectl (MIN-79, `appset-eval` only) in jobs that do not use them. That costs a couple of seconds and removes the entire
# class of bug: there is no per-job subset to get wrong. A job-specific tool list
# is exactly what just broke.
#
# Versions come from the environment — deploy-pr-opened.yml's `env:` block is the
# single place they are pinned, so this script never becomes a second source of
# truth for a version number.
set -euo pipefail

: "${HELM_VERSION:?HELM_VERSION must be set by the workflow env block}"
: "${KUSTOMIZE_VERSION:?KUSTOMIZE_VERSION must be set by the workflow env block}"
: "${KUBECONFORM_VERSION:?KUBECONFORM_VERSION must be set by the workflow env block}"
: "${KYVERNO_VERSION:?KYVERNO_VERSION must be set by the workflow env block}"
: "${KIND_VERSION:?KIND_VERSION must be set by the workflow env block}"
: "${KUBECTL_VERSION:?KUBECTL_VERSION must be set by the workflow env block}"

BIN_DIR="${BIN_DIR:-/usr/local/bin}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cd "${TMP}"

echo "== helm ${HELM_VERSION} =="
curl -fsSL -o helm.tar.gz "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
tar -xzf helm.tar.gz linux-amd64/helm
sudo install -m 0755 linux-amd64/helm "${BIN_DIR}/helm"

echo "== kustomize ${KUSTOMIZE_VERSION} =="
curl -fsSL -o kustomize.tar.gz \
  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
tar -xzf kustomize.tar.gz kustomize
sudo install -m 0755 kustomize "${BIN_DIR}/kustomize"

echo "== kubeconform ${KUBECONFORM_VERSION} =="
curl -fsSL -o kubeconform.tar.gz \
  "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz"
tar -xzf kubeconform.tar.gz kubeconform
sudo install -m 0755 kubeconform "${BIN_DIR}/kubeconform"

echo "== kyverno ${KYVERNO_VERSION} =="
curl -fsSL -o kyverno.tar.gz \
  "https://github.com/kyverno/kyverno/releases/download/v${KYVERNO_VERSION}/kyverno-cli_v${KYVERNO_VERSION}_linux_x86_64.tar.gz"
tar -xzf kyverno.tar.gz kyverno
sudo install -m 0755 kyverno "${BIN_DIR}/kyverno"

# kind + kubectl: used only by the `appset-eval` job (MIN-79), installed in every
# job anyway — the "no per-job subset" rule above. `--retry 3` on these two (MIN-77 /
# TSG-034: one dropped packet must not fail a gate); the older lines will follow
# when MIN-77 lands rather than widening this change.
echo "== kind ${KIND_VERSION} =="
curl -fsSL --retry 3 -o kind \
  "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64"
sudo install -m 0755 kind "${BIN_DIR}/kind"

# Same k8s minor as the kind node image and the cluster's k3s (v1.31) — kubectl
# supports ±1 minor skew, so matching removes the question instead of answering it.
echo "== kubectl ${KUBECTL_VERSION} =="
curl -fsSL --retry 3 -o kubectl \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl "${BIN_DIR}/kubectl"

echo
echo "== installed =="
helm version --short
kustomize version
kubeconform -v
# NOT `kyverno version | head -1`. That form exits **141** (128 + SIGPIPE) under
# the `set -euo pipefail` this repo mandates (IRD-014 §Bash script standards):
# `head` reads its one line and closes the pipe, `kyverno` is still writing, gets
# SIGPIPE, and `pipefail` promotes that to the pipeline's status. Every tool
# installed correctly and the script still failed on its last line — CI exit 141
# with no error message, because SIGPIPE prints nothing.
# Note that shellcheck cannot see this: it is a runtime interaction between
# pipefail and a short-reading consumer, not a syntax issue. Print all three
# lines instead; there is nothing to truncate.
# (This comment is deliberately NOT started with the word "shellcheck" — a
# comment beginning `# shellcheck ...` is parsed as a DIRECTIVE, and this one
# tripped SC1072/SC1073 in its first draft.)
kyverno version
kind version
kubectl version --client
