{{- define "estateflow-admin-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "estateflow-admin-service.fullname" -}}
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

{{- define "estateflow-admin-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "estateflow-admin-service.labels" -}}
helm.sh/chart: {{ include "estateflow-admin-service.chart" . }}
{{ include "estateflow-admin-service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "estateflow-admin-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "estateflow-admin-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "estateflow-admin-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "estateflow-admin-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
  adminServiceEnv: map of env name -> string/number/bool OR nested map (e.g. valueFrom) for Kubernetes.
  Mirrors EstateFlow-Service docker-compose.yml **estateflow-admin** service environment.
*/}}
{{- define "estateflow-admin-service.adminEnvYaml" -}}
{{- range $k, $v := .Values.adminServiceEnv }}
- name: {{ $k }}
{{- if kindIs "map" $v }}
{{ toYaml $v | indent 2 }}
{{- else }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end }}
