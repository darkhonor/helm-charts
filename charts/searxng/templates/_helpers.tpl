{{/*
Expand the name of the chart.
*/}}
{{- define "searxng.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "searxng.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Allow the release namespace to be overridden for multi-namespace deployments in combined charts
*/}}
{{- define "searxng.namespace" -}}
  {{- if .Values.namespaceOverride -}}
    {{- .Values.namespaceOverride -}}
  {{- else -}}
    {{- .Release.Namespace -}}
  {{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "searxng.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "searxng.labels" -}}
helm.sh/chart: {{ include "searxng.chart" . }}
{{ include "searxng.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "searxng.selectorLabels" -}}
app.kubernetes.io/name: {{ include "searxng.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "searxng.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "searxng.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Determine the Secret name for SearXNG secret_key.
Uses existingSecret if set, otherwise generates name from fullname.
*/}}
{{- define "searxng.secretName" -}}
{{- if .Values.secrets.searxngSecret.existingSecret -}}
  {{- .Values.secrets.searxngSecret.existingSecret -}}
{{- else -}}
  {{- printf "%s-secret" (include "searxng.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Determine if the internal Valkey subchart should be deployed.
*/}}
{{- define "searxng.valkeyEnabled" -}}
{{- if eq .Values.valkey.mode "internal" -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Resolve the Valkey hostname based on mode.
Internal: subchart service name. External: user-provided host.
*/}}
{{- define "searxng.valkeyHost" -}}
{{- if eq .Values.valkey.mode "internal" -}}
  {{- printf "%s-valkey.%s.svc.cluster.local" (include "searxng.fullname" .) (include "searxng.namespace" .) -}}
{{- else -}}
  {{- required "valkey.external.host is required when valkey.mode is external" .Values.valkey.external.host -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the Valkey port based on mode.
*/}}
{{- define "searxng.valkeyPort" -}}
{{- if eq .Values.valkey.mode "internal" -}}
  {{- 6379 -}}
{{- else -}}
  {{- .Values.valkey.external.port | default 6379 -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the Valkey database number based on mode.
*/}}
{{- define "searxng.valkeyDB" -}}
{{- if eq .Values.valkey.mode "internal" -}}
  {{- 0 -}}
{{- else -}}
  {{- .Values.valkey.external.db | default 0 -}}
{{- end -}}
{{- end -}}

{{/*
Determine the URL scheme based on TLS setting.
*/}}
{{- define "searxng.valkeyScheme" -}}
{{- if .Values.valkey.tls.enabled -}}
  {{- "valkeys" -}}
{{- else -}}
  {{- "valkey" -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the Valkey auth Secret name.
Uses existingSecret if set, otherwise generates from fullname.
*/}}
{{- define "searxng.valkeyAuthSecretName" -}}
{{- if .Values.valkey.auth.existingSecret -}}
  {{- .Values.valkey.auth.existingSecret -}}
{{- else -}}
  {{- printf "%s-valkey-auth" (include "searxng.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the Valkey TLS Secret name.
Uses existingSecret if set, otherwise generates from fullname.
*/}}
{{- define "searxng.valkeyTlsSecretName" -}}
{{- if .Values.valkey.tls.existingSecret -}}
  {{- .Values.valkey.tls.existingSecret -}}
{{- else -}}
  {{- printf "%s-valkey-tls" (include "searxng.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Build the full SEARXNG_REDIS_URL.
When auth is enabled, uses $(VALKEY_PASSWORD) for Kubernetes dependent env var
resolution at container start.
*/}}
{{- define "searxng.redisURL" -}}
{{- $scheme := include "searxng.valkeyScheme" . -}}
{{- $host := include "searxng.valkeyHost" . -}}
{{- $port := include "searxng.valkeyPort" . -}}
{{- $db := include "searxng.valkeyDB" . -}}
{{- if .Values.valkey.auth.enabled -}}
  {{- printf "%s://:$(VALKEY_PASSWORD)@%s:%s/%s" $scheme $host $port $db -}}
{{- else -}}
  {{- printf "%s://%s:%s/%s" $scheme $host $port $db -}}
{{- end -}}
{{- end -}}
