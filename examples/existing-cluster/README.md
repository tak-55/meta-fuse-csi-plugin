# 既存クラスタ向け設定 example

運用中の S3 / SFTP に対して検証したい場合は、この example ファイルをテンプレートとして使い、実際の設定は git 管理外のローカルファイルに置いてください。`s3fs` の external test では、`s3.env` の access key / secret key から一時的な `passwd_file` を生成して、その認証情報を明示的に使います。region 指定が必要な場合は `S3_REGION` も設定してください。Restricted な non-root Pod からアクセスしやすくするため、`s3fs` には既定で `-o umask=000` を渡します。生成される検証 Pod は PSS restricted な non-root 設定を維持しつつ、`/data` を `starter` の 1 コンテナだけに mount します。

推奨レイアウト:

```text
cluster-test-config/
├── s3.env
├── sshfs.env
└── sshfs/
    ├── id_ed25519
    └── known_hosts   # 任意ですが推奨
```

準備後は次のように実行します。

```console
$ cp ./examples/existing-cluster/s3.env.example ./cluster-test-config/s3.env
$ cp ./examples/existing-cluster/sshfs.env.example ./cluster-test-config/sshfs.env
$ ./test_existing_cluster.sh --config-dir ./cluster-test-config
$ ./render_external_s3fs_manifest.sh --config-dir ./cluster-test-config > /tmp/external-s3fs.yaml
$ kubectl apply -f /tmp/external-s3fs.yaml
```

そのまま雛形として使える運用向け manifest も用意しています。

- `examples/existing-cluster/production-s3fs-deployment.yaml`
- `examples/existing-cluster/production-sshfs-deployment.yaml`

どちらも `Deployment + restartable init sidecar + app container` の構成で、user Pod は `restricted` / non-root のまま `/data` を app container から参照できます。production manifest の `/data` は read-write です。必要に応じて `metadata.namespace` を追加してください。secret / endpoint / app image は実環境の値に置き換えてください。

SSHFS では `allow_other` / `umask=000` により non-root app container からアクセスしやすくしていますが、inode の owner 表示と実際の write 可否は別です。owner を `1000:1000` 風に見せたい場合は `SSHFS_ARGS="-o idmap=user -o uid=1000 -o gid=1000"` のように追加できます。ただし write 可否そのものは SFTP server 側の directory / file 権限で決まります。
