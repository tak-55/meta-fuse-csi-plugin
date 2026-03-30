# Copilot instructions for `meta-fuse-csi-plugin`

## Build and test

- Build the Go binaries with `make driver`, `make fuse-starter`, or `make fusermount3-proxy`.
- Build container images with `make build-driver` and `make build-examples`.
- Build everything the repo uses locally with `make all`.
- Run the unit tests with `go test ./...`.
- Run a single test with the Go test runner, for example `go test ./pkg/util -run TestParseEndpoint -v` or `go test ./pkg/csi_mounter -run TestPrepareMountArgs -v`.
- Run the example checks with `make test-examples`.
- Run the kind-based end-to-end flow with `make test-e2e`.
- The helper scripts `build-for-kind.sh` and `test_e2e.sh` are the repo’s scripted local/kind workflows; they both rely on `make all`, Kubernetes manifests in `deploy/`, and the example manifests under `examples/`.

## High-level architecture

- This repository implements a CSI node plugin that lets pods mount FUSE filesystems without giving the workload `CAP_SYS_ADMIN`.
- The cluster-facing component is the CSI driver DaemonSet in `deploy/`. It only exposes node-side behavior; the `Driver` wires CSI identity and node servers together and starts a non-blocking gRPC server.
- Mounting is split into two approaches:
  - `pkg/fuse_starter` handles the direct file-descriptor-passing flow. The sidecar/container receives `/dev/fuse` from the CSI driver over a Unix socket and then launches the FUSE implementation with that fd.
  - `cmd/fusermount3-proxy` and `pkg/csi_mounter` implement the libfuse3-style proxy flow. The proxy behaves like `fusermount3` and passes the mount fd through the CSI driver side channel.
- `pkg/csi_driver/node.go` is the main runtime path. `NodePublishVolume` validates ephemeral volume context, creates the mount target, coordinates access with a per-target lock, and uses the mounter abstraction to set up the FUSE mount. `NodeUnpublishVolume` tears the mount down and also closes/unregisters the fd-passing socket when needed.
- `pkg/util` contains shared helpers for endpoint parsing, socket message passing, label parsing, pod/volume path parsing, and volume locks.

## Key conventions

- Build metadata is injected at link time via `STAGINGVERSION` and `BUILD_DATE`; the binaries log `version` and `builddate` at startup.
- The driver name is fixed at `meta-fuse-csi-plugin.csi.storage.pfn.io`; keep manifests, examples, and code in sync with that string.
- `NodePublishVolume` expects these `VolumeContext` keys for the ephemeral workflow: `csi.storage.k8s.io/ephemeral`, `fdPassingEmptyDirName`, and `fdPassingSocketName`.
- The code assumes kubelet’s CSI mount path layout when parsing pod and volume IDs. If you touch path handling, check `util.ParsePodIDVolumeFromTargetpath` and the callers together.
- Example pods use restartable init containers / sidecars so the FUSE filesystem is mounted before the application container starts. The README and example manifests treat that ordering as required.
- Tests are table-driven and commonly call `t.Parallel()`. When adding new coverage, follow the same style used in `pkg/util/util_test.go` and `pkg/csi_mounter/csi_mounter_test.go`.
- Mount option handling is intentionally split: mount options intended for the CSI layer are filtered separately from sidecar-only options. Review `pkg/csi_mounter.prepareMountOptions` before changing option parsing.
