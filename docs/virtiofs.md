# VirtIO-FS in a PVE guest

Upstream ImmortalWrt 24.10 ships **no** `kmod-fs-virtiofs` package, and the
generic kernel config has `# CONFIG_VIRTIO_FS is not set`. This repository adds
the module itself:

```
package/kernel/linux/modules/fs-virtiofs.mk
```

`scripts/build.sh` copies it into `<source>/package/kernel/linux/modules/`,
which `package/kernel/linux/Makefile` includes via `modules/*.mk`. The package
is selected as `CONFIG_PACKAGE_kmod-fs-virtiofs=y` (see `config/packages.config`
and `features.virtiofs.enabled`).

## Verify the module is present

```bash
zcat /proc/config.gz | grep VIRTIO_FS      # expects =m or =y
opkg list-installed | grep virtiofs
modprobe virtiofs && dmesg | tail -5
```

## PVE host side

```bash
# VM config (/etc/pve/qemu-server/<vmid>.conf)
args: -object memory-backend-memfd,id=mem,size=1024M,share=on -numa node,memdev=mem
       -chardev socket,id=char0,path=/run/virtiofsd-<vmid>.sock
       -device vhost-user-fs-pci,chardev=char0,tag=hostshare
memory: 2048
```

Start `virtiofsd` on the host:

```bash
virtiofsd --socket-path=/run/virtiofsd-<vmid>.sock \
          --shared-dir /tank/share --cache=auto
```

## Guest side

```bash
mkdir -p /mnt/host
mount -t virtiofs hostshare /mnt/host
# persist:
echo 'hostshare /mnt/host virtiofs defaults 0 0' >> /etc/fstab
```

## 9p alternative

9p works without any in-tree module change (`kmod-fs-9p`, `kmod-9pnet`,
`kmod-9pvirtio` all exist upstream):

```bash
# host args:
#  -fsdev local,id=fsdev0,path=/tank/share,security_model=passthrough \
#  -device virtio-9p-pci,fsdev=fsdev0,mount_tag=hostshare
mkdir -p /mnt/host
mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host
```
