# VirtIO-FS 使用指南

ImmortalWrt 上游 openwrt-24.10 **没有** `kmod-fs-virtiofs` 包，本仓库在
`package/kernel/linux/modules/fs-virtiofs.mk` 中自带该 KernelPackage：

- KCONFIG：`CONFIG_FUSE_FS=y`、`CONFIG_VIRTIO_FS=y`（内核 6.6 的
  `fs/fuse/virtio_fs.ko` 已包含 virtiofs 客户端）
- FILES：`virtio_fs.ko` + `fuse.ko`
- AUTOLOAD：`virtio_fs fuse`
- 依赖：`kmod-fuse`，并附带 `fuse-utils`（config.yml `features.virtiofs.fuse`）

## PVE 宿主机侧

PVE 官方尚未把 vhost-user-fs 做进 GUI；两种可行方案：

### 1. qm set 手动挂 vhost-user-fs-pci（需要 qemu-server 支持 spawn_extra）

```bash
# 宿主机共享目录 /srv/share -> guest tag "hostshare"
qm set <VMID> --args '-chardev socket,id=chrdev_vufs,path=/run/vhost-fs/hostshare.sock,server=on,wait=off \
 -device vhost-user-fs-pci,chardev=chrdev_vufs,tag=hostshare'
```

需自行运行 `virtiofsd --socket-path=/run/vhost-fs/hostshare.sock \
 --shared-dir=/srv/share --announce-self --sandbox none`（或 systemd 单元）。

### 2. 退而求其次：virtio-9p（PVE GUI 原生支持 "Directory Backup/Mount Point"）

本镜像同时内置 kmod-fs-9p + kmod-virtio-9p：

```bash
mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/9p
```

## Guest 内挂载 virtiofs

```bash
modprobe virtio_fs        # AUTOLOAD 已处理，可跳过
mkdir -p /mnt/virtiofs
mount -t virtiofs hostshare /mnt/virtiofs
# fstab 持久化：
echo 'hostshare /mnt/virtiofs virtiofs defaults 0 0' >> /etc/fstab
```

## 验证

```bash
lsmod | grep -E 'virtio_fs|fuse'
cat /proc/filesystems | grep virtiofs
```

若 `/proc/filesystems` 无 `virtiofs`，说明构建时 `CONFIG_VIRTIO_FS` 未生效，
检查 `.config` 是否含 `CONFIG_PACKAGE_kmod-fs-virtiofs=y`。
