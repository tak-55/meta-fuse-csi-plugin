# 既存クラスタ向け設定 example

運用中の S3 / SFTP に対して検証したい場合は、この example ファイルをテンプレートとして使い、実際の設定は git 管理外のローカルファイルに置いてください。`s3fs` の external test では、`s3.env` の access key / secret key から一時的な `passwd_file` を生成して、その認証情報を明示的に使います。region 指定が必要な場合は `S3_REGION` も設定してください。

推奨レイアウト:

```text
cluster-test-config/
├── s3.env
├── sshfs.env
└── sshfs/
    ├── id_ed25519
    └── known_hosts   # 任意ですが推奨
```

準備後は次のように実行します:

```console
$ cp ./examples/existing-cluster/s3.env.example ./cluster-test-config/s3.env
$ cp ./examples/existing-cluster/sshfs.env.example ./cluster-test-config/sshfs.env
$ ./test_existing_cluster.sh --config-dir ./cluster-test-config
$ ./render_external_s3fs_manifest.sh --config-dir ./cluster-test-config > /tmp/external-s3fs.yaml
$ kubectl apply -f /tmp/external-s3fs.yaml
```
