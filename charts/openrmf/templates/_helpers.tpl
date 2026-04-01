{{/*
Expand the name of the chart.
*/}}
{{- define "openrmf.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated at 63 characters per DNS naming spec.
*/}}
{{- define "openrmf.fullname" -}}
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
Create chart name and version for chart label.
*/}}
{{- define "openrmf.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Namespace override support.
*/}}
{{- define "openrmf.namespace" -}}
{{- if .Values.namespaceOverride -}}
{{- .Values.namespaceOverride -}}
{{- else -}}
{{- .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "openrmf.labels" -}}
helm.sh/chart: {{ include "openrmf.chart" . }}
{{ include "openrmf.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "openrmf.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openrmf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "openrmf.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "openrmf.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve Keycloak URL for application configuration.
Internal mode: in-cluster service URL.
External mode: user-provided URL from values.
*/}}
{{- define "openrmf.keycloakURL" -}}
{{- if eq .Values.keycloak.mode "internal" -}}
{{- printf "http://%s-keycloakx.%s.svc.cluster.local:8080/auth" (include "openrmf.fullname" .) (include "openrmf.namespace" .) -}}
{{- else -}}
{{- required "keycloak.external.url is required when keycloak.mode is external" .Values.keycloak.external.url -}}
{{- end -}}
{{- end -}}

{{/*
Resolve Keycloak realm.
*/}}
{{- define "openrmf.keycloakRealm" -}}
{{- if eq .Values.keycloak.mode "internal" -}}
{{- .Values.keycloak.internal.realm | default "openrmf" -}}
{{- else -}}
{{- .Values.keycloak.external.realm | default "openrmf" -}}
{{- end -}}
{{- end -}}

{{/*
OIDC secret name.
*/}}
{{- define "openrmf.oidcSecretName" -}}
{{- if eq .Values.keycloak.mode "external" -}}
{{- required "keycloak.external.existingSecret is required when keycloak.mode is external" .Values.keycloak.external.existingSecret -}}
{{- else -}}
{{- printf "%s-oidc" (include "openrmf.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
MongoDB secret name.
*/}}
{{- define "openrmf.mongodbSecretName" -}}
{{- if eq .Values.mongodb.mode "external" -}}
{{- required "mongodb.external.existingSecret is required when mongodb.mode is external" .Values.mongodb.external.existingSecret -}}
{{- else -}}
{{- printf "%s-mongodb" (include "openrmf.fullname" .) -}}
{{- end -}}
{{- end -}}
