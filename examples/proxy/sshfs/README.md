# fusermount3-proxy with sshfs

sshfs uses libfuse to handle FUSE operations.

libfuse uses fusermount3 only when it succeeded to open "/dev/fuse" and failed to mount FUSE due to EPERM.
The detail is shown in https://github.com/libfuse/libfuse/blob/05b696edb347dc555f937c1439ffda6a1c40416e/lib/mount.c#L523

To allow libfuse to call fusermount3 while keeping the user pod compatible with `restricted`, the example mounts a regular file from an `emptyDir` onto `/dev/fuse` instead of creating it from inside the container.
