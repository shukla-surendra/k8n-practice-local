{{- define "backend.fullname" -}}
{{ .Release.Name }}-backend
{{- end }}

{{- define "backend.labels" -}}
app.kubernetes.io/name: backend
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: backend
app.kubernetes.io/part-of: full-stack-app
{{- end }}

{{- define "backend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ include "backend.fullname" . }}
{{- else -}}
{{ .Values.serviceAccount.name | default "default" }}
{{- end -}}
{{- end }}
