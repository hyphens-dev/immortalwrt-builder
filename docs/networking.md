# 网络特性：WireGuard / nftables / bridge / veth / tun

对应 `config.yml` 的 `features.network.*`，由 `scripts/build.sh` 翻译为包选择。

## WireGuard

- `kmod-wireguard` + `wireguard-tools`（`wg` 命令）+ `luci-app-wireguard`
- PVE guest 内需要内核 `tun` 与 UDP 卸载；本镜像已带 `kmod-tun`。
- LuCI: 网络 → 接口 → 添加 WireGuard VPN 接口。
- CLI 快速验证：

```sh
wg genkey | tee privatekey | wg pubkey > publickey
ip link add dev wg0 type wireguard
ip address add dev wg0 10.0.0.2/24
wg set wg0 peer <PEER_PUBKEY> endpoint 198.51.100.1:51820 allowed-ips 0.0.0.0/0
ip link set up dev wg0
```

## nftables（firewall4）

openwrt-24.10 默认防火墙后端即 firewall4/nftables：

- `nftables-json`、`kmod-nft-bridge/tproxy/nat/iptables`
- `iptables-nft`/`ip6tables-nft` 兼容层保留（旧脚本可用，底层仍是 nft）
- conntrack 调优见 `/etc/sysctl.d/900-pve-tuning.conf`

常用检查：`nft list ruleset`、`service firewall restart`。

## bridge / veth / tun

- `br-lan` 已在 overlay `/etc/config/network` 中默认创建（eth0 入桥）。
- `kmod-bridge`、`kmod-veth`、`kmod-tun`、`bridge-utils`。
- 典型旁路由拓扑：PVE `vmbr0` ↔ guest `br-lan(eth0)`；容器/VM 穿透用 veth：

```sh
ip link add veth0 type veth peer name veth1
ip link set veth1 master br-lan   # 或放进独立 bridge
ip link set veth0 up && ip link set veth1 up
```

- `tun` 供 WireGuard/其他隧道使用；如需容器化代理可 `mkdir -p /dev/net && mknod /dev/net/tun c 10 200`（init 时 rc.local 可扩展）。

## PVE 侧注意

- `net0=virtio,bridge=vmbr0`，virtio-net 多队列由 hotplug 脚本
  `/etc/hotplug.d/iface/90-virtio-queues` 自动开启（需 PVE 给网卡配置 `queues=N`）。
- 关闭 guest 不需要的 VLAN offload 排障时可 `ethtool -K eth0 tx off rx off`。
