{{/*
Expand the name of the chart.
*/}}
{{- define "resourceName" -}}
{{- printf "%s" $.Values.global.projectName | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fullResourceName" -}}
{{- printf "%s-%s" .projectName .serviceName }}
{{- end }}

{{- define "labels" -}}
project: {{ .global.projectName | quote }}
module: {{ .module | quote }}
{{- with .global.asset }}
pttep.com/asset: {{ . | quote }}
{{- end }}
{{- end }}

{{- define "replica-strategy" -}}
{{- $replicaCount := int (.global.replicaCount | default 1) }}
replicas: {{ $replicaCount }}
{{- if (gt $replicaCount 1) }}
{{- with .global.rollloutStrategy }}
strategy:
  {{- toYaml . | nindent 4 }}
{{- end }}
{{- end }}
{{- end }}

{{- define "deployment-image" }}
{{- $imageRegistry :=  default "docker.io" .image.registry .global.image.registry }}
{{- $imageRepository := default "" .image.repository .global.image.repository }}
{{- $imageSubPath := default "" .image.subpath .global.image.subpath }}
{{- $imageTag := default "latest" .image.tag .global.image.tag }}
{{- $imagePullPolicy := .image.pullPolicy }}
{{- $globalPullPolicy := .global.image.pullPolicy }}
{{- $pullPolicyParams := (dict "imageTag" $imageTag "imagePullPolicy" $imagePullPolicy "globalPullPolicy" $globalPullPolicy) }}
image: {{ printf "%s/%s/%s:%s" $imageRegistry $imageRepository $imageSubPath $imageTag | replace "//" "/" | replace "/:" ":" }}
imagePullPolicy: {{ include "imagePullPolicy" $pullPolicyParams }}
{{ end -}}

{{- define "pod-annotations" -}}
project: {{ $.Values.global.projectName }}
proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'
cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
deployment.checksum/config: {{ include (print $.Template.BasePath "/configmap.yml") $ | sha256sum | quote }}
deployment.checksum/secret: {{ include (print $.Template.BasePath "/secret.yml") $ | sha256sum | quote }}
{{- end }}

{{- define "init-copy-secret" -}}
- name: init-secret-fs-permission
  image: busybox:latest
  resources:
    limits:
      cpu: 100m
      memory: 0.25Gi
  env:
    - name: HOME
      value: "$HOME_DIR"
  command:
    - sh
    - -c
    - apk add --no-cache tree &&
      cp -LR $HOME/mnt/* $HOME/vault/ && 
      chown -R 1001:1001 $HOME/vault && 
      chmod -R 500 $HOME/vault && chmod -R 400 $HOME/vault/* && 
      tree $HOME/vault
  securityContext:
    runAsUser: 0
  volumeMounts:
    - mountPath: {{ .homeDir }}/mnt/expose-configmaps
      name: {{ include "resourceName" .root }}-{{ .module }}-expose-cm-volume
    - mountPath: {{ .homeDir }}/mnt/configmaps
      name: {{ include "resourceName" .root }}-{{ .module }}-cm-volume
    - mountPath: {{ .homeDir }}/mnt/secrets
      name: {{ include "resourceName" .root }}-{{ .module }}-secret-volume
    - mountPath: {{ .homeDir }}/vault
      name: vault-volume
{{- end }}

{{- define "imagePullPolicy" -}}
{{- $imageTag := .imageTag -}}
{{- $imagePullPolicy := .imagePullPolicy -}}
{{- $globalImagePullPolicy := .globalPullPolicy -}}
{{- if eq $imageTag "latest" -}}
"Always"
{{- else }}
{{- default "IfNotPresent" $imagePullPolicy $globalImagePullPolicy -}}
{{- end }}
{{- end }}


{{/*
Selector labels
*/}}
{{- define "..selectorLabels" -}}
app.kubernetes.io/name: {{ include "resourceName" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "app-container" -}}
- name: {{ lower .name | quote }}
  {{- include "deployment-image" (dict "image" .service.image "global" .root.Values.global) | trim | nindent 2 }}
  resources:
    {{- toYaml (.service.resources | default .root.Values.global.resources | default dict) | trim | nindent 4 -}}
  {{- with .service.ports }}
  ports:
    {{- toYaml . | trim | nindent 4 }}
  {{- end }}
  {{- with .service.probes.livenessProbe}}
  livenessProbe:
    {{- toYaml . | trim | nindent 4 }}
  {{- end }}
  {{- with .service.probes.readinessProbe }}
  readinessProbe:
    {{- toYaml . | trim | nindent 4 }}
  {{- end }}
  {{- with .service.probes.startupProbe}}
  startupProbe:
    {{- toYaml . | trim | nindent 4 }}
  {{- end }}
  {{- with .service.envs }}
  env:
    {{- range $envKey, $envValue := . }}
    {{- if and $envValue (kindIs "map" $envValue) }}
    - name: {{ $envKey | trim | quote }}
      {{ $envValue | toYaml | trim | nindent 6 }}
    {{- end }}
    {{- if (kindIs "string" $envValue) }}
    - name: {{ upper $envKey | trim | quote }}
      value: {{ $envValue | trim | quote }}
    {{- end }}
    {{- end }}
    {{- end }}
  volumeMounts:
    - name: vault-volume
      mountPath: /home/swadm/vault
    {{- if and .service.exposeConfigMaps (kindIs "map" .service.exposeConfigMaps) }}
    - name: {{ include "resourceName" .root }}-{{ .name }}-cm-volume
      mountPath: {{ (.service.exposeConfigMaps.mountPath | quote) | default "/secrets/config.json"  }}
    {{- end }}
    {{- with .service.persistentVolumes -}}
    {{- if .enabled }}
    {{- range $claimName, $meta := .claims -}}
    {{- $resourceNameParams := dict "projectName" .root.Values.global.projectName "serviceName" .name }}
    - name: {{ $claimName }}-data
      {{- $defaultMountPath := printf "/mnt/%s/%s" .name $claimName -}}
      mountPath: {{ $meta.mountPath | default $defaultMountPath }}
    {{- end }}
    {{- end }}
    {{- end }}
    {{- with .service.additionalVolumesMounts -}}
    {{ toYaml .service.additionalVolumesMounts | trim | nindent 12 }}
    {{ end }}
{{- end -}}