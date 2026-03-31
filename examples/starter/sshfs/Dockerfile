FROM golang:1.20.7 AS fuse-starter-builder

WORKDIR /meta-fuse-csi-plugin
ADD . .
RUN make fuse-starter BINDIR=/bin

FROM ubuntu:22.04
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        fuse3 \
        libfuse2 \
        openssh-server \
        sshfs \
        wget && \
    rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash --uid 1000 app

WORKDIR /home/app
ENV HOME=/home/app

RUN mkdir -p /home/app/.ssh /home/app/sshd /home/app/sshfs-example/subdir && \
    ssh-keygen -q -t ed25519 -f /home/app/.ssh/id_ed25519 -N "" && \
    cp /home/app/.ssh/id_ed25519.pub /home/app/.ssh/authorized_keys && \
    ssh-keygen -q -t ed25519 -f /home/app/sshd/ssh_host_ed25519_key -N "" && \
    cat <<'EOF' > /home/app/.ssh/config
Host localhost
    HostName 127.0.0.1
    Port 2222
    User app
    IdentityFile /home/app/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
RUN cat <<'EOF' > /home/app/sshd/sshd_config
Port 2222
ListenAddress 127.0.0.1
HostKey /home/app/sshd/ssh_host_ed25519_key
AuthorizedKeysFile /home/app/.ssh/authorized_keys
PidFile /home/app/sshd/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
PubkeyAuthentication yes
Subsystem sftp internal-sftp
EOF

RUN echo "This file is an example for sshfs" > /home/app/sshfs-example/subdir/test.txt && \
    chown -R app:app /home/app && \
    chmod 700 /home/app/.ssh /home/app/sshd && \
    chmod 600 /home/app/.ssh/id_ed25519 /home/app/.ssh/authorized_keys /home/app/sshd/ssh_host_ed25519_key

COPY <<'EOF' /entrypoint.sh
#!/bin/bash
set -euo pipefail

/usr/sbin/sshd -D -e -f /home/app/sshd/sshd_config &
sleep 1

/mfcp-bin/fuse-starter --fd-passing-socket-path /fuse-fd-passing/fuse-csi-ephemeral.sock -- \
  /usr/bin/sshfs app@127.0.0.1:/home/app/sshfs-example /dev/fd/3 -f \
  -p 2222 \
  -o allow_other \
  -o umask=000 \
  -o IdentityFile=/home/app/.ssh/id_ed25519 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null &

wait -n
exit $?
EOF

RUN chmod +x /entrypoint.sh

RUN mkdir /mfcp-bin
COPY --from=fuse-starter-builder /bin/fuse-starter /mfcp-bin/fuse-starter

USER 1000:1000

CMD ["/entrypoint.sh"]
