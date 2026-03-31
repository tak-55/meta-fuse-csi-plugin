#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)

REGISTRY="ghcr.io/tak-55/meta-fuse-csi-plugin"
IMAGE_TAG="latest"
CONFIG_DIR=""
RUN_HOSTUSERS_SMOKE=true
DEPLOY_DRIVER=true
RUN_S3FS=true
RUN_PROXY_SSHFS=true
RUN_STARTER_SSHFS=true
ROLLOUT_TIMEOUT="300s"

usage() {
    cat <<'EOF'
Usage: ./test_existing_cluster.sh [options]

Validate the published GHCR images on an existing Linux Kubernetes cluster.

By default the script runs the self-contained examples in this repository.
To test against operational S3 / SFTP endpoints instead, put local config files
under a git-ignored directory and pass --config-dir.

Options:
  --registry REGISTRY           Container registry prefix
  --image-tag TAG               Image tag to test (default: latest)
  --config-dir DIR              Directory containing local S3 / SSHFS config files
  --skip-hostusers-smoke        Skip the hostUsers:false smoke test
  --skip-driver-deploy          Skip applying the CSI driver manifests
  --skip-s3fs                   Skip s3fs validation
  --skip-proxy-sshfs            Skip proxy/sshfs validation
  --skip-starter-sshfs          Skip starter/sshfs validation
  --rollout-timeout DURATION    DaemonSet rollout timeout (default: 300s)
  -h, --help                    Show this help

Examples:
  ./test_existing_cluster.sh
  ./test_existing_cluster.sh --image-tag sha-0123456789ab
  ./test_existing_cluster.sh --config-dir ./cluster-test-config
  ./test_existing_cluster.sh --config-dir ./cluster-test-config --skip-driver-deploy
EOF
}

cleanup() {
    kubectl delete pod hostusers-smoke --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete secret mfcp-cluster-test-s3 --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete secret mfcp-cluster-test-sshfs --ignore-not-found >/dev/null 2>&1 || true
    rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --image-tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --config-dir)
            CONFIG_DIR="$2"
            shift 2
            ;;
        --skip-hostusers-smoke)
            RUN_HOSTUSERS_SMOKE=false
            shift
            ;;
        --skip-driver-deploy)
            DEPLOY_DRIVER=false
            shift
            ;;
        --skip-s3fs)
            RUN_S3FS=false
            shift
            ;;
        --skip-proxy-sshfs)
            RUN_PROXY_SSHFS=false
            shift
            ;;
        --skip-starter-sshfs)
            RUN_STARTER_SSHFS=false
            shift
            ;;
        --rollout-timeout)
            ROLLOUT_TIMEOUT="$2"
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

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

require_command kubectl
require_command sed

DRIVER_IMAGE="${REGISTRY}/meta-fuse-csi-plugin:${IMAGE_TAG}"
PROXY_S3FS_IMAGE="${REGISTRY}/mfcp-example-proxy-s3fs:${IMAGE_TAG}"
PROXY_SSHFS_IMAGE="${REGISTRY}/mfcp-example-proxy-sshfs:${IMAGE_TAG}"
STARTER_SSHFS_IMAGE="${REGISTRY}/mfcp-example-starter-sshfs:${IMAGE_TAG}"
if [[ "${IMAGE_TAG}" == "latest" ]]; then
    IMAGE_PULL_POLICY="Always"
else
    IMAGE_PULL_POLICY="IfNotPresent"
fi

echo "Using images:"
echo "  driver:        ${DRIVER_IMAGE}"
echo "  proxy/s3fs:    ${PROXY_S3FS_IMAGE}"
echo "  proxy/sshfs:   ${PROXY_SSHFS_IMAGE}"
echo "  starter/sshfs: ${STARTER_SSHFS_IMAGE}"
echo "  pull policy:   ${IMAGE_PULL_POLICY}"

if [[ -n "${CONFIG_DIR}" ]]; then
    echo "Using external config from: ${CONFIG_DIR}"
fi

wait_for_pod_ready() {
    local pod_name="$1"
    kubectl wait --for=condition=Ready "pod/${pod_name}" --timeout=300s
}

wait_for_fuse_mounted() {
    local pod_name="$1"
    local container_name="$2"
    until kubectl exec "${pod_name}" -c "${container_name}" -- /bin/sh -c 'mount | grep fuse >/dev/null'; do
        echo "waiting for fuse mount in ${pod_name}/${container_name}"
        sleep 1
    done
}

assert_file_content() {
    local pod_name="$1"
    local container_name="$2"
    local mounted_file="$3"
    local expected_content="$4"
    local actual_content

    actual_content=$(kubectl exec "${pod_name}" -c "${container_name}" -- /bin/sh -c "cat '${mounted_file}'")
    if [[ "${actual_content}" != "${expected_content}" ]]; then
        echo "Content mismatch for ${mounted_file}" >&2
        echo "expected: ${expected_content}" >&2
        echo "actual:   ${actual_content}" >&2
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

run_hostusers_smoke() {
    echo "Running hostUsers:false smoke test..."
    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hostusers-smoke
spec:
  hostUsers: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: main
    image: busybox
    command: ["sleep", "60"]
    securityContext:
      privileged: false
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
EOF
    kubectl wait --for=condition=Ready pod/hostusers-smoke --timeout=60s
    kubectl delete pod hostusers-smoke
}

deploy_driver() {
    echo "Deploying CSI driver..."
    kubectl apply -f "${SCRIPT_DIR}/deploy/csi-driver.yaml"
    sed \
        -e "s#ghcr.io/tak-55/meta-fuse-csi-plugin/meta-fuse-csi-plugin:latest#${DRIVER_IMAGE}#" \
        -e "s#imagePullPolicy: Always#imagePullPolicy: ${IMAGE_PULL_POLICY}#" \
        "${SCRIPT_DIR}/deploy/csi-driver-daemonset.yaml" | kubectl apply -f -
    if ! kubectl rollout status ds/meta-fuse-csi-plugin -n mfcp-system --timeout="${ROLLOUT_TIMEOUT}"; then
        echo "CSI driver rollout failed; collecting pod diagnostics..." >&2
        kubectl get pods -n mfcp-system -o wide >&2 || true
        kubectl describe pods -n mfcp-system >&2 || true
        return 1
    fi
}

prepare_self_contained_manifests() {
    mkdir -p \
        "${TMP_DIR}/examples/proxy/s3fs" \
        "${TMP_DIR}/examples/proxy/sshfs" \
        "${TMP_DIR}/examples/starter/sshfs"

    sed \
        -e "s#ghcr.io/tak-55/meta-fuse-csi-plugin/mfcp-example-proxy-s3fs:latest#${PROXY_S3FS_IMAGE}#" \
        -e "s#imagePullPolicy: Always#imagePullPolicy: ${IMAGE_PULL_POLICY}#" \
        "${SCRIPT_DIR}/examples/proxy/s3fs/deploy.yaml" \
        > "${TMP_DIR}/examples/proxy/s3fs/deploy.yaml"

    sed \
        -e "s#ghcr.io/tak-55/meta-fuse-csi-plugin/mfcp-example-proxy-sshfs:latest#${PROXY_SSHFS_IMAGE}#" \
        -e "s#imagePullPolicy: Always#imagePullPolicy: ${IMAGE_PULL_POLICY}#" \
        "${SCRIPT_DIR}/examples/proxy/sshfs/deploy.yaml" \
        > "${TMP_DIR}/examples/proxy/sshfs/deploy.yaml"

    sed \
        -e "s#ghcr.io/tak-55/meta-fuse-csi-plugin/mfcp-example-starter-sshfs:latest#${STARTER_SSHFS_IMAGE}#" \
        -e "s#imagePullPolicy: Always#imagePullPolicy: ${IMAGE_PULL_POLICY}#" \
        "${SCRIPT_DIR}/examples/starter/sshfs/deploy.yaml" \
        > "${TMP_DIR}/examples/starter/sshfs/deploy.yaml"
}

run_self_contained_s3fs() {
    echo "Testing proxy/s3fs..."
    "${SCRIPT_DIR}/examples/check.sh" \
        "${TMP_DIR}/examples/proxy/s3fs" \
        mfcp-example-proxy-s3fs \
        starter \
        /test.txt \
        starter \
        /data/subdir/test.txt
}

run_self_contained_proxy_sshfs() {
    echo "Testing proxy/sshfs..."
    "${SCRIPT_DIR}/examples/check.sh" \
        "${TMP_DIR}/examples/proxy/sshfs" \
        mfcp-example-proxy-sshfs \
        starter \
        /home/app/sshfs-example/subdir/test.txt \
        starter \
        /data/subdir/test.txt
}

run_self_contained_starter_sshfs() {
    echo "Testing starter/sshfs..."
    "${SCRIPT_DIR}/examples/check.sh" \
        "${TMP_DIR}/examples/starter/sshfs" \
        mfcp-example-starter-sshfs \
        starter \
        /home/app/sshfs-example/subdir/test.txt \
        starter \
        /data/subdir/test.txt
}

prepare_external_s3() {
    local -a s3_secret_args
    local s3_region_arg=""

    load_env_file "${CONFIG_DIR}/s3.env"

    : "${S3_BUCKET:?S3_BUCKET is required}"
    : "${S3_ENDPOINT:?S3_ENDPOINT is required}"
    : "${S3_TEST_FILE:?S3_TEST_FILE is required}"
    : "${S3_EXPECTED_CONTENT:?S3_EXPECTED_CONTENT is required}"
    : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
    : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

    s3_secret_args=(
        --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
        --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
    )
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
        s3_secret_args+=(--from-literal=AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}")
    fi
    if [[ -n "${S3_REGION:-}" ]]; then
        s3_region_arg="-o endpoint=${S3_REGION}"
    fi

    kubectl create secret generic mfcp-cluster-test-s3 \
        "${s3_secret_args[@]}" \
        --dry-run=client -o yaml | kubectl apply -f -

    cat > "${TMP_DIR}/external-s3fs.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mfcp-external-proxy-s3fs
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
      printf '%s:%s\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" > /s3fs-passwd/passwd-s3fs
    envFrom:
    - secretRef:
        name: mfcp-cluster-test-s3
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      privileged: false
    volumeMounts:
    - name: s3fs-passwd
      mountPath: /s3fs-passwd
  containers:
  - name: starter
    image: ${PROXY_S3FS_IMAGE}
    imagePullPolicy: ${IMAGE_PULL_POLICY}
    command: ["/bin/bash", "-lc"]
    args:
    - |
      exec s3fs "${S3_BUCKET}" /tmp -f -o passwd_file=/s3fs-passwd/passwd-s3fs -o url="${S3_ENDPOINT}" ${s3_region_arg} ${S3FS_ARGS:-}
    env:
    - name: FUSERMOUNT3PROXY_FDPASSING_SOCKPATH
      value: /fusermount3-proxy/fuse-csi-ephemeral.sock
    envFrom:
    - secretRef:
        name: mfcp-cluster-test-s3
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

run_external_s3() {
    echo "Testing proxy/s3fs against external S3..."
    kubectl apply -f "${TMP_DIR}/external-s3fs.yaml"
    wait_for_pod_ready mfcp-external-proxy-s3fs
    wait_for_fuse_mounted mfcp-external-proxy-s3fs starter
    assert_file_content mfcp-external-proxy-s3fs starter "/data/${S3_TEST_FILE}" "${S3_EXPECTED_CONTENT}"
    kubectl delete -f "${TMP_DIR}/external-s3fs.yaml"
}

prepare_external_sshfs() {
    local -a sshfs_secret_args

    load_env_file "${CONFIG_DIR}/sshfs.env"

    : "${SSHFS_HOST:?SSHFS_HOST is required}"
    : "${SSHFS_PORT:?SSHFS_PORT is required}"
    : "${SSHFS_USER:?SSHFS_USER is required}"
    : "${SSHFS_REMOTE_PATH:?SSHFS_REMOTE_PATH is required}"
    : "${SSHFS_TEST_FILE:?SSHFS_TEST_FILE is required}"
    : "${SSHFS_EXPECTED_CONTENT:?SSHFS_EXPECTED_CONTENT is required}"

    SSHFS_KEY_PATH="${CONFIG_DIR}/sshfs/id_ed25519"
    SSHFS_KNOWN_HOSTS_PATH="${CONFIG_DIR}/sshfs/known_hosts"

    if [[ ! -f "${SSHFS_KEY_PATH}" ]]; then
        echo "Missing SSH private key: ${SSHFS_KEY_PATH}" >&2
        exit 1
    fi

    sshfs_secret_args=(--from-file=id_ed25519="${SSHFS_KEY_PATH}")
    if [[ -f "${SSHFS_KNOWN_HOSTS_PATH}" ]]; then
        sshfs_secret_args+=(--from-file=known_hosts="${SSHFS_KNOWN_HOSTS_PATH}")
    fi

    kubectl create secret generic mfcp-cluster-test-sshfs \
        "${sshfs_secret_args[@]}" \
        --dry-run=client -o yaml | kubectl apply -f -

    cat > "${TMP_DIR}/external-proxy-sshfs.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mfcp-external-proxy-sshfs
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
  containers:
  - name: starter
    image: ${PROXY_SSHFS_IMAGE}
    imagePullPolicy: ${IMAGE_PULL_POLICY}
    command: ["/bin/bash", "-lc"]
    args:
    - |
      set -euo pipefail
      known_hosts_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
      if [ -f /ssh-config/known_hosts ]; then
        known_hosts_args="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/ssh-config/known_hosts"
      fi
      exec /usr/bin/sshfs "${SSHFS_USER}@${SSHFS_HOST}:${SSHFS_REMOTE_PATH}" /tmp -f -p "${SSHFS_PORT}" -o IdentityFile=/ssh-config/id_ed25519 ${SSHFS_ARGS:-} ${known_hosts_args}
    env:
    - name: FUSERMOUNT3PROXY_FDPASSING_SOCKPATH
      value: /fusermount3-proxy/fuse-csi-ephemeral.sock
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
    - name: ssh-config
      mountPath: /ssh-config
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
  volumes:
  - name: fuse-fd-passing
    emptyDir: {}
  - name: fake-dev-fuse
    emptyDir: {}
  - name: ssh-config
    secret:
      secretName: mfcp-cluster-test-sshfs
      defaultMode: 0400
  - name: fuse-csi-ephemeral
    csi:
      driver: meta-fuse-csi-plugin.csi.storage.pfn.io
      readOnly: true
      volumeAttributes:
        fdPassingEmptyDirName: fuse-fd-passing
        fdPassingSocketName: fuse-csi-ephemeral.sock
EOF

    cat > "${TMP_DIR}/external-starter-sshfs.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mfcp-external-starter-sshfs
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
  containers:
  - name: starter
    image: ${STARTER_SSHFS_IMAGE}
    imagePullPolicy: ${IMAGE_PULL_POLICY}
    command: ["/bin/bash", "-lc"]
    args:
    - |
      set -euo pipefail
      known_hosts_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
      if [ -f /ssh-config/known_hosts ]; then
        known_hosts_args="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/ssh-config/known_hosts"
      fi
      exec /mfcp-bin/fuse-starter --fd-passing-socket-path /fuse-fd-passing/fuse-csi-ephemeral.sock -- /usr/bin/sshfs "${SSHFS_USER}@${SSHFS_HOST}:${SSHFS_REMOTE_PATH}" /dev/fd/3 -f -p "${SSHFS_PORT}" -o IdentityFile=/ssh-config/id_ed25519 ${SSHFS_ARGS:-} ${known_hosts_args}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      privileged: false
    volumeMounts:
    - name: fuse-fd-passing
      mountPath: /fuse-fd-passing
    - name: ssh-config
      mountPath: /ssh-config
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
  volumes:
  - name: fuse-fd-passing
    emptyDir: {}
  - name: ssh-config
    secret:
      secretName: mfcp-cluster-test-sshfs
      defaultMode: 0400
  - name: fuse-csi-ephemeral
    csi:
      driver: meta-fuse-csi-plugin.csi.storage.pfn.io
      readOnly: true
      volumeAttributes:
        fdPassingEmptyDirName: fuse-fd-passing
        fdPassingSocketName: fuse-csi-ephemeral.sock
EOF
}

run_external_proxy_sshfs() {
    echo "Testing proxy/sshfs against external SFTP..."
    kubectl apply -f "${TMP_DIR}/external-proxy-sshfs.yaml"
    wait_for_pod_ready mfcp-external-proxy-sshfs
    wait_for_fuse_mounted mfcp-external-proxy-sshfs starter
    assert_file_content mfcp-external-proxy-sshfs starter "/data/${SSHFS_TEST_FILE}" "${SSHFS_EXPECTED_CONTENT}"
    kubectl delete -f "${TMP_DIR}/external-proxy-sshfs.yaml"
}

run_external_starter_sshfs() {
    echo "Testing starter/sshfs against external SFTP..."
    kubectl apply -f "${TMP_DIR}/external-starter-sshfs.yaml"
    wait_for_pod_ready mfcp-external-starter-sshfs
    wait_for_fuse_mounted mfcp-external-starter-sshfs starter
    assert_file_content mfcp-external-starter-sshfs starter "/data/${SSHFS_TEST_FILE}" "${SSHFS_EXPECTED_CONTENT}"
    kubectl delete -f "${TMP_DIR}/external-starter-sshfs.yaml"
}

if [[ "${RUN_HOSTUSERS_SMOKE}" == "true" ]]; then
    run_hostusers_smoke
fi

if [[ "${DEPLOY_DRIVER}" == "true" ]]; then
    deploy_driver
fi

if [[ -z "${CONFIG_DIR}" ]]; then
    prepare_self_contained_manifests

    if [[ "${RUN_S3FS}" == "true" ]]; then
        run_self_contained_s3fs
    fi

    if [[ "${RUN_PROXY_SSHFS}" == "true" ]]; then
        run_self_contained_proxy_sshfs
    fi

    if [[ "${RUN_STARTER_SSHFS}" == "true" ]]; then
        run_self_contained_starter_sshfs
    fi
else
    if [[ "${RUN_S3FS}" == "true" ]]; then
        prepare_external_s3
        run_external_s3
    fi

    if [[ "${RUN_PROXY_SSHFS}" == "true" || "${RUN_STARTER_SSHFS}" == "true" ]]; then
        prepare_external_sshfs
    fi

    if [[ "${RUN_PROXY_SSHFS}" == "true" ]]; then
        run_external_proxy_sshfs
    fi

    if [[ "${RUN_STARTER_SSHFS}" == "true" ]]; then
        run_external_starter_sshfs
    fi
fi

echo "Cluster validation finished successfully."
