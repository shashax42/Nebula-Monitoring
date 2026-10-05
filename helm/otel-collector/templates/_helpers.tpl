{{/*
Expand the name of the chart.
*/}}
{{- define "otel-collector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "otel-collector.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "otel-collector.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "otel-collector.labels" -}}
helm.sh/chart: {{ include "otel-collector.chart" . }}
{{ include "otel-collector.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "otel-collector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "otel-collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component helpers. Call with (dict "root" $ "name" "agent")
*/}}
{{- define "otel-collector.componentFullname" -}}
{{- printf "%s-%s" (include "otel-collector.fullname" .root) .name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "otel-collector.componentLabels" -}}
{{ include "otel-collector.labels" .root }}
app.kubernetes.io/component: {{ .name }}
{{- end }}

{{- define "otel-collector.componentSelectorLabels" -}}
{{ include "otel-collector.selectorLabels" .root }}
app.kubernetes.io/component: {{ .name }}
{{- end }}

{{- define "otel-collector.serviceAccountName" -}}
{{- $c := index .root.Values .name -}}
{{- if $c.serviceAccount.create }}
{{- default (include "otel-collector.componentFullname" .) $c.serviceAccount.name }}
{{- else }}
{{- default "default" $c.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Gateway endpoints used by agent/cluster exporters
*/}}
{{- define "otel-collector.gatewayHost" -}}
{{- printf "%s.%s.svc" (include "otel-collector.componentFullname" (dict "root" . "name" "gateway")) .Release.Namespace }}
{{- end }}

{{- define "otel-collector.gatewayHeadlessHost" -}}
{{- printf "%s-headless.%s.svc.cluster.local" (include "otel-collector.componentFullname" (dict "root" . "name" "gateway")) .Release.Namespace }}
{{- end }}

{{- define "otel-collector.logGroup" -}}
{{- $root := .root -}}
{{- $explicit := index $root.Values.global.aws.cloudwatch (printf "%sLogGroup" .kind) | default "" -}}
{{- if $explicit }}{{ $explicit }}{{ else }}{{ printf "/aws/eks/%s/%s" $root.Values.global.clusterName .suffix }}{{ end -}}
{{- end }}

{{/*
Environment shared by every component. The collector config references these via ${env:VAR}.
*/}}
{{- define "otel-collector.env" -}}
{{- $root := .root -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: K8S_NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
- name: K8S_NODE_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
- name: CLUSTER_NAME
  value: {{ required "global.clusterName is required" $root.Values.global.clusterName | quote }}
- name: ENVIRONMENT
  value: {{ $root.Values.global.environment | quote }}
- name: AWS_REGION
  value: {{ $root.Values.global.aws.region | quote }}
- name: GATEWAY_OTLP_ENDPOINT
  value: {{ printf "%s:4317" (include "otel-collector.gatewayHost" $root) | quote }}
- name: GATEWAY_HEADLESS_HOST
  value: {{ include "otel-collector.gatewayHeadlessHost" $root | quote }}
- name: SELF_LOG_GLOB
  value: {{ printf "/var/log/pods/%s_%s-*/*/*.log" $root.Release.Namespace (include "otel-collector.fullname" $root) | quote }}
- name: LOG_MIN_SEVERITY_NUMBER
  value: {{ $root.Values.pipeline.logs.minSeverityNumber | quote }}
{{- if eq .name "gateway" }}
- name: AMP_REMOTE_WRITE_URL
  value: {{ required "global.aws.ampRemoteWriteUrl is required (terraform output -raw amp_remote_write_url)" $root.Values.global.aws.ampRemoteWriteUrl | quote }}
- name: CW_LOG_GROUP_APP
  value: {{ include "otel-collector.logGroup" (dict "root" $root "kind" "application" "suffix" "application") | quote }}
- name: CW_LOG_GROUP_EVENTS
  value: {{ include "otel-collector.logGroup" (dict "root" $root "kind" "events" "suffix" "events") | quote }}
- name: CW_LOG_GROUP_AUDIT
  value: {{ include "otel-collector.logGroup" (dict "root" $root "kind" "audit" "suffix" "audit") | quote }}
- name: CW_LOG_GROUP_EMF
  value: {{ include "otel-collector.logGroup" (dict "root" $root "kind" "emf" "suffix" "metrics") | quote }}
- name: TRACE_BASELINE_SAMPLING_PERCENT
  value: {{ $root.Values.pipeline.traces.baselineSamplingPercent | quote }}
- name: TRACE_LATENCY_THRESHOLD_MS
  value: {{ $root.Values.pipeline.traces.latencyThresholdMs | quote }}
- name: TRACE_CRITICAL_SERVICES_REGEX
  value: {{ $root.Values.pipeline.traces.criticalServicesRegex | quote }}
- name: TRACE_CRITICAL_SAMPLING_PERCENT
  value: {{ $root.Values.pipeline.traces.criticalSamplingPercent | quote }}
- name: SLI_LATENCY_THRESHOLD_MS
  value: {{ $root.Values.pipeline.sli.latencyThresholdMs | quote }}
{{- end }}
{{- if and (eq .name "cluster") $root.Values.cluster.messaging.rabbitmq.enabled }}
- name: RABBITMQ_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $root.Values.cluster.messaging.rabbitmq.passwordSecret.name }}
      key: {{ $root.Values.cluster.messaging.rabbitmq.passwordSecret.key }}
{{- end }}
{{- end }}

{{/*
Final collector config for a component (adds optional receivers on top of values).
*/}}
{{- define "otel-collector.config" -}}
{{- $root := .root -}}
{{- $c := index $root.Values .name -}}
{{- $cfg := deepCopy $c.config -}}
{{- if eq .name "cluster" -}}
{{- $metrics := index $cfg.service.pipelines "metrics" -}}
{{- with $root.Values.cluster.messaging.kafka -}}
{{- if .enabled -}}
{{- $_ := set $cfg.receivers "kafka_metrics" (dict "brokers" (required "cluster.messaging.kafka.brokers is required" .brokers) "protocol_version" .protocolVersion "client_id" .clientId "scrapers" (list "brokers" "topics" "consumers") "collection_interval" "30s") -}}
{{- $_ := set $metrics "receivers" (append $metrics.receivers "kafka_metrics") -}}
{{- end -}}
{{- end -}}
{{- with $root.Values.cluster.messaging.rabbitmq -}}
{{- if .enabled -}}
{{- $_ := set $cfg.receivers "rabbitmq" (dict "endpoint" .endpoint "username" .username "password" "${env:RABBITMQ_PASSWORD}" "collection_interval" "30s") -}}
{{- $_ := set $metrics "receivers" (append $metrics.receivers "rabbitmq") -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $cfg -}}
{{- end }}
