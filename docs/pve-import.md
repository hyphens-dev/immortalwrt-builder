# PVE 导入与推荐 VM 配置

## 1. 转换并导入磁盘

```bash
# 下载 CI 构件 immortalwrt-pve-x86-64/*.img.gz
gunzip immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz

# 建一个无磁盘 VM（UEFI + DHCP）
qm create 101 --name immortalwrt --memory 2048 --cores 4 \
  --cpu host --ostype l26 --net0 virtio,bridge=vmbr0 \
  --bios ovmf --efidisk0 local-lvm:1,efitype=4m,type=1 \
  --scsihw virtio-scsi-single --agent enabled=1

qm importdisk 101 immortalwrt-*.img local-lvm
qm set 101 --scsi0 local-lvm:vm-101-disk-0,discard=on,ssd=1
qm set 101 --boot order=scsi0
qm set 101 --rng0 source=/dev/urandom      # virtio-rng
qm set 101 --balloon 0                      # 关内存气球或按需
qm start 101
```

要点：

- **CPU type=host**：暴露宿主指令集，配合 irqbalance/多队列收益最大。
- **virtio 全套**：磁盘 scsi0=virtio-scsi（或直接 virtioblk）、net0=virtio、
  rng0=virtio-rng —— 与内核 built-in 驱动一一对应。
- 首次启动后管理 IP 为 config.yml 的 `build.lan_ip`（默认 192.168.100.1），
  LuCI 入口 `http://192.168.100.1`，密码为空（root 登录后可改）。

## 2. 网络直通/桥接选择

| 场景 | PVE 配置 | guest 配置 |
|------|----------|-----------|
| 主路由 | net0=virtio,bridge=vmbr0（vmbr0 上联 WAN 口） | eth0→br-lan(static)，另加 net1 WAN |
| 旁路由 | 同上 + vmbr0 保持 LAN | lan 静态 IP，网关指主路由 |
| VLAN | net0 tag 或独立 bridge | config/network 增加 device vlan |

## 3. VirtIO-FS / 9P 共享

见 [virtiofs.md](virtiofs.md)。PVE GUI 的 "Mount Point (Directory)" 走 virtio-9p，
本镜像已内置客户端模块，guest 内：

```sh
mount -t 9p -o trans=virtio,rversion=9p2000.L <tag> /mnt/9p
```

## 4. 快照升级

固件镜像式升级 = 重新导入新 img；保留配置可用 `sysupgrade`：

```sh
wget -O /tmp/fw.bin <release>/sysupgrade.bin
sysupgrade -n /tmp/fw.bin
```
