#!/bin/bash

set -euo pipefail

REGISTRY="ghcr.io/tak-55/meta-fuse-csi-plugin"
IMAGE_TAG="latest"
CONFIG_DIR=""
NAMESPACE="default"
POD_NAME="mfcp-external-proxy-s3fs"
SECRET_NAME="mfcp-cluster-test-s3"
CONFIGMAP_NAME="mfcp-cluster-test-s3fs-config"
OUTPUT="-"

usage() {
    cat <<'EOF'
Usage: ./render_external_s3fs_manifest.sh --config-dir DIR [options]

Render a Kubernetes manifest for proxy/s3fs using the external S3 settings in
DIR/s3.env. The output includes:
  - Secret with AWS credentials
  - ConfigMap with bucket/endpoint/options
  - Pod manifest using mfcp-example-proxy-s3fs

Options:
  --config-dir DIR          Directory containing s3.env
  --registry REGISTRY       Container registry prefix
  --image-tag TAG           Image tag to use (default: latest)
  --namespace NAMESPACE     Namespace for rendered resources (default: default)
  --pod-name NAME           Pod name (default: mfcp-external-proxy-s3fs)
  --secret-name NAME        Secret name (default: mfcp-cluster-test-s3)
  --configmap-name NAME     ConfigMap name (default: mfcp-cluster-test-s3fs-config)
  --output PATH             Write manifest to PATH instead of stdout
  -h, --help                Show this help

Example:
  ./render_external_s3fs_manifest.sh --config-dir ./cluster-test-config > external-s3fs.yaml
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

load_env_file() {
    local env_file="$1"
    if [[ ! -f "${env_file}" ]]; then
        echo "Missing config file: ${env_file}" >&2
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir)
            CONFIG_DIR="$2"
            shift 2
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --image-tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --pod-name)
            POD_NAME="$2"
            shift 2
            ;;
        --secret-name)
            SECRET_NAME="$2"
            shift 2
            ;;
        --configmap-name)
            CONFIGMAP_NAME="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "${CONFIG_DIR}" ]]; then
    echo "--config-dir is required" >&2
    usage >&2
    exit 1
fi

require_command kubectl

load_env_file "${CONFIG_DIR}/s3.env"

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

if [[ "${IMAGE_TAG}" == "latest" ]]; then
    IMAGE_PULL_POLICY="Always"
else
    IMAGE_PULL_POLICY="IfNotPresent"
fi

IMAGE="${REGISTRY}/mfcp-example-proxy-s3fs:${IMAGE_TAG}"

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

secret_args=(
    --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
    --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
)
if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
    secret_args+=(--from-literal=AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}")
fi

configmap_args=(
    --from-literal=S3_BUCKET="${S3_BUCKET}"
    --from-literal=S3_ENDPOINT="${S3_ENDPOINT}"
)
if [[ -n "${S3_REGION:-}" ]]; then
    configmap_args+=(--from-literal=S3_REGION="${S3_REGION}")
fi
if [[ -n "${S3FS_ARGS:-}" ]]; then
    configmap_args+=(--from-literal=S3FS_ARGS="${S3FS_ARGS}")
fi

kubectl create secret generic "${SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    "${secret_args[@]}" \
    --dry-run=client -o yaml > "${tmp_dir}/secret.yaml"

kubectl create configmap "${CONFIGMAP_NAME}" \
    --namespace "${NAMESPACE}" \
    "${configmap_args[@]}" \
    --dry-run=client -o yaml > "${tmp_dir}/configmap.yaml"

emit_manifest() {
    cat "${tmp_dir}/secret.yaml"
    printf -- "---\n"
    cat "${tmp_dir}/configmap.yaml"
    cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  terminationGracePeriodSeconds: 10
  hostUsers: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  initContainers:
  - name: prepare-fuse-dev
    image: busybox
    command: ["sh", "-c", "touch /fake-dev/fuse && chmod 0666 /fake-dev/fuse"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      privileged: false
    volumeMounts:
    - name: fake-dev-fuse
      mountPath: /fake-dev
  - name: prepare-s3fs-passwd
    image: busybox
    command: ["/bin/sh", "-c"]
    args:
    - |
      umask 077
      printf '%s:%s\n' "\$AWS_ACCESS_KEY_ID" "\$AWS_SECRET_ACCESS_KEY" > /s3fs-passwd/passwd-s3fs
    envFrom:
    - secretRef:
        name: ${SECRET_NAME}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      privileged: false
    volumeMounts:
    - name: s3fs-passwd
      mountPath: /s3fs-passwd
  - name: starter
    restartPolicy: Always
    image: ${IMAGE}
    imagePullPolicy: ${IMAGE_PULL_POLICY}
    command: ["/bin/bash", "-lc"]
    args:
    - |
      region_arg=""
      if [[ -n "\${S3_REGION:-}" ]]; then
        region_arg="-o endpoint=\${S3_REGION}"
      fi
      exec s3fs "\$S3_BUCKET" /tmp -f -o passwd_file=/s3fs-passwd/passwd-s3fs -o url="\$S3_ENDPOINT" \${region_arg} \${S3FS_ARGS:-}
    env:
    - name: FUSERMOUNT3PROXY_FDPASSING_SOCKPATH
      value: /fusermount3-proxy/fuse-csi-ephemeral.sock
    envFrom:
    - secretRef:
        name: ${SECRET_NAME}
    - configMapRef:
        name: ${CONFIGMAP_NAME}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      privileged: false
    volumeMounts:
    - name: fuse-fd-passing
      mountPath: /fusermount3-proxy
    - name: fake-dev-fuse
      mountPath: /dev/fuse
      subPath: fuse
    - name: s3fs-passwd
      mountPath: /s3fs-passwd
      readOnly: true
    - name: fuse-csi-ephemeral
      mountPath: /data
      readOnly: true
      mountPropagation: HostToContainer
    startupProbe:
      exec:
        command: ["sh", "-c", "mount | grep /data | grep fuse"]
      failureThreshold: 300
      periodSeconds: 1
  containers:
  - name: busybox
    image: busybox
    command: ["sleep", "infinity"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      privileged: false
    volumeMounts:
    - name: fuse-csi-ephemeral
      mountPath: /data
      readOnly: true
      mountPropagation: HostToContainer
  volumes:
  - name: fuse-fd-passing
    emptyDir: {}
  - name: fake-dev-fuse
    emptyDir: {}
  - name: s3fs-passwd
    emptyDir: {}
  - name: fuse-csi-ephemeral
    csi:
      driver: meta-fuse-csi-plugin.csi.storage.pfn.io
      readOnly: true
      volumeAttributes:
        fdPassingEmptyDirName: fuse-fd-passing
        fdPassingSocketName: fuse-csi-ephemeral.sock
EOF
}

if [[ "${OUTPUT}" == "-" ]]; then
    emit_manifest
else
    emit_manifest > "${OUTPUT}"
    echo "Wrote manifest to ${OUTPUT}"
fi
