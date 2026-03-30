# 既存クラスタ向け設定 example

運用中の S3 / SFTP に対して検証したい場合は、この example ファイルをテンプレートとして使い、実際の設定は git 管理外のローカルファイルに置いてください。

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
```
