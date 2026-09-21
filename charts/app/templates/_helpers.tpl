{{/*
  Shared helpers for the app chart (IRD-017).
  Every template uses these so the label set is identical across all 5 services —
  which is what makes one ServiceMonitor selector, one PDB selector and one
  `kubectl get all -l app.kubernetes.io/part-of=task-management` work.
*/}}

{{/* The service name. Required — fail loudly rather than render a nameless object. */}}
{{- define "app.name" -}}
{{- required "service.name is required (IRD-017 values schema)" .Values.service.name -}}
{{- end -}}

{{/*
  Standard Kubernetes recommended labels.
  `version` is deliberately omitted: the image tag is an immutable SHA set by the
  overlay, and putting it in a label would make every deploy churn the selector's
  neighbourhood for no benefit.
*/}}
{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: task-management
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
  Selector labels — the STABLE subset. These land in Deployment.spec.selector,
  which is immutable after creation, so nothing volatile may ever appear here.
*/}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
  Fully-qualified image reference.
  Both repository and tag are required: an empty tag must fail the render, never
  silently become `:latest` (Kyverno disallow-latest-tag, IRD-007/IRD-021).
  In practice the overlay's `images:` transformer rewrites this line anyway —
  this guard is for a base rendered on its own.
*/}}
{{- define "app.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- $tag  := required "image.tag is required — the overlay's images: transformer sets the immutable SHA" .Values.image.tag -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
