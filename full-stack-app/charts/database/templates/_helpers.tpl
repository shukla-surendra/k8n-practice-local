{{- define "database.fullname" -}}
{{ .Release.Name }}-database
{{- end }}

{{- define "database.labels" -}}
app.kubernetes.io/name: database
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: database
app.kubernetes.io/part-of: full-stack-app
{{- end }}
