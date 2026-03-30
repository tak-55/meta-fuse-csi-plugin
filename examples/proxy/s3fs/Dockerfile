FROM golang:1.20.7 AS fusermount3-proxy-builder

WORKDIR /meta-fuse-csi-plugin
ADD . .
RUN make fusermount3-proxy BINDIR=/bin

FROM ubuntu:22.04
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        fuse3 \
        libfuse2 \
        s3fs \
        wget && \
    rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash --uid 1000 app

# prepare for MinIO
RUN wget https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc -O /usr/bin/mc && chmod +x /usr/bin/mc

WORKDIR /home/app
ENV HOME=/home/app

COPY <<EOF /home/app/test.txt
This is a test file for minio
EOF

COPY <<EOF /home/app/configure_minio.sh
#!/bin/bash
set -eux
/usr/bin/mc alias set k8s-minio-dev http://localhost:9000 minioadmin minioadmin
/usr/bin/mc mb k8s-minio-dev/test-bucket
/usr/bin/mc cp /home/app/test.txt k8s-minio-dev/test-bucket/subdir/
EOF
RUN ln -sf /home/app/test.txt /test.txt && \
    chmod +x /home/app/configure_minio.sh && \
    chown -R app:app /home/app

COPY --from=fusermount3-proxy-builder /bin/fusermount3-proxy /bin/fusermount3
RUN ln -sf /bin/fusermount3 /bin/fusermount

USER 1000:1000
