{{/*
Shutdown settings shared by every connector container (FD-1939).
Spring Boot reads SERVER_SHUTDOWN and SPRING_LIFECYCLE_TIMEOUT-PER-SHUTDOWN-PHASE directly;
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
{{- end }}
