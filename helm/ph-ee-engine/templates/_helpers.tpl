{{/*
Shutdown settings shared by every connector container (FD-1939).
Spring Boot reads SERVER_SHUTDOWN and SPRING_LIFECYCLE_TIMEOUT-PER-SHUTDOWN-PHASE directly; they cover
the Spring web server port. CAMEL_SPRINGBOOT_SHUTDOWN-TIMEOUT covers the Camel HTTP port and every
other Camel route: Camel finishes in-flight exchanges for up to that many seconds, then stops them.
ZEEBE_WORKER_DRAIN-TIMEOUT is read by the ZeebeWorkerDrain component in each connector image
and ignored by images that do not have it yet.
*/}}
{{- define "ph-ee-engine.shutdown.env" -}}
- name: SERVER_SHUTDOWN
  value: "graceful"
- name: SPRING_LIFECYCLE_TIMEOUT-PER-SHUTDOWN-PHASE
  value: "{{ .Values.gracefulShutdown.phaseTimeout }}"
- name: ZEEBE_WORKER_DRAIN-TIMEOUT
  value: "{{ .Values.gracefulShutdown.zeebeDrainTimeout }}"
- name: CAMEL_SPRINGBOOT_SHUTDOWN-TIMEOUT
  value: "{{ .Values.gracefulShutdown.camelShutdownTimeout }}"
{{- end }}

{{/*
Extra environment variables for one connector container (FD-1935). Lets operators change any Spring
property of the image without a chart change, for example the per-endpoint timeout, retry and
circuit-breaker settings (MPESA_RESILIENCE_STKQUERY_READTIMEOUT, FINERACT_RESILIENCE_CONFIRMATION_RETRY_MAXATTEMPTS,
...). Pass the connector's values block; its optional extraEnv is a list of env entries in the Kubernetes shape
(name/value or name/valueFrom).
*/}}
{{- define "ph-ee-engine.extraEnv" -}}
{{- with .extraEnv }}
{{- range . }}
- name: {{ .name | quote }}
{{- if .valueFrom }}
  valueFrom:
{{ toYaml .valueFrom | indent 4 }}
{{- else }}
  value: {{ .value | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
