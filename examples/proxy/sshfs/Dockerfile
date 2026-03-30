FROM golang:1.20.7 AS fusermount3-proxy-builder

WORKDIR /meta-fuse-csi-plugin
ADD . .
RUN make fusermount3-proxy BINDIR=/bin

FROM ubuntu:22.04
ARG TARGETARCH

RUN apt update && apt upgrade -y
RUN apt install -y ca-certificates wget libfuse2 fuse3

# install sshfs
RUN apt install -y sshfs

RUN apt install -y openssh-server
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

/usr/bin/sshfs app@127.0.0.1:/home/app/sshfs-example /tmp -f \
  -p 2222 \
  -o IdentityFile=/home/app/.ssh/id_ed25519 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null &

wait -n
exit $?
EOF

RUN chmod +x /entrypoint.sh

COPY --from=fusermount3-proxy-builder /bin/fusermount3-proxy /bin/fusermount3
RUN ln -sf /bin/fusermount3 /bin/fusermount

USER 1000:1000

CMD ["/entrypoint.sh"]
