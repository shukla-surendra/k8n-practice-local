{{/* Full resource name: <release>-frontend */}}
{{- define "frontend.fullname" -}}
{{ .Release.Name }}-frontend
{{- end }}

{{/* Standard labels applied to every resource in this subchart */}}
{{- define "frontend.labels" -}}
app.kubernetes.io/name: frontend
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: frontend
app.kubernetes.io/part-of: full-stack-app
{{- end }}

{{/* Name of the ServiceAccount to use — created or user-supplied */}}
{{- define "frontend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ include "frontend.fullname" . }}
{{- else -}}
{{ .Values.serviceAccount.name | default "default" }}
{{- end -}}
{{- end }}
