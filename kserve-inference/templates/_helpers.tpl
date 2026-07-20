{{/*
_helpers.tpl — reusable snippets called by other templates with "include"
*/}}

{{/* Resource name: nameOverride if set, otherwise the release name */}}
{{- define "kserve-inference.fullname" -}}
{{- .Values.nameOverride | default .Release.Name -}}
{{- end }}

{{/* Standard labels added to every resource */}}
{{- define "kserve-inference.labels" -}}
app.kubernetes.io/name: {{ include "kserve-inference.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.labels }}
{{ toYaml . }}
{{- end }}
{{- end }}
