{{/*
_helpers.tpl — reusable snippets called by other templates with "include"
*/}}

{{/* Full name: release-name + chart-name, e.g. "myrelease-my-app" */}}
{{- define "my-app.fullname" -}}
{{ .Release.Name }}-{{ .Chart.Name }}
{{- end }}

{{/* Standard labels added to every resource */}}
{{- define "my-app.labels" -}}
app: {{ include "my-app.fullname" . }}
env: {{ .Values.env }}
{{- end }}
