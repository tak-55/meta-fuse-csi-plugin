restricted-first FUSE design - User Pod should stay PSS restricted and non-privileged; `hostUsers: false` is optional and not a required success condition.
CSI node plugin privilege boundary - Keep privileged operations in the DaemonSet; `mfcp-system` needs PSA privileged labels.
s3fs baseline - Prefer `-o umask=000` for restricted non-root Pods; avoid overfitting uid/gid workarounds for userns.
sshfs baseline - Prefer `-o allow_other -o umask=000`; owner display can be adjusted with `SSHFS_ARGS="-o idmap=user -o uid=1000 -o gid=1000"`.
sshfs write semantics - Visible uid/gid mapping does not grant write access; write permission is still determined by remote SFTP path permissions.
production manifests - `examples/existing-cluster/production-{s3fs,sshfs}-deployment.yaml` are the current production templates; `/data` is read-write and `metadata.namespace` is intentionally omitted.
external cluster config - Use `cluster-test-config/{s3.env,sshfs.env,sshfs/id_ed25519,sshfs/known_hosts}` with `test_existing_cluster.sh`.
validation pattern - Use `bash -n` for scripts and `ruby -e 'require "yaml"; YAML.load_stream(...)'` for manifest sanity checks.
