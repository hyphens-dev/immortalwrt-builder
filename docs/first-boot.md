# 首次开机：SSH 与 Web 界面

## 双网卡主路由（推荐）

`build.nic_layout: "router"`（默认）会把两块网卡按下面方式使用：

| PVE 网卡 | 设备 | 作用 | config.yml |
|---|---|---|---|
| `net0` → `vmbr0` | eth0 | **WAN** | `build.wan_mode` / `wan_ip` / `wan_gateway` / `wan_dns` / `wan6_mode` |
| `net1` → `vmbr1` | eth1 | **LAN**（br-lan） | `build.lan_ip` / `lan_netmask` / `lan_dhcp_start` / `lan_dhcp_limit` |

生成的 `/etc/config/network` 大致是：

```
config device
	option name 'br-lan'
	option type 'bridge'
	list ports eth1

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ip6assign '60'
	list ipaddr 10.10.10.254/24

config interface 'wan'
	option device eth0
	option proto static
	list ipaddr 192.168.60.253/24
	option gateway 192.168.60.254
	list dns 192.168.60.254
	list dns 223.5.5.5

config interface 'wan6'
	option device eth0
	option proto dhcpv6
	...
```

**地址池必须跟 LAN 网段一致。** `lan_dhcp_start` / `lan_dhcp_limit` 是相对网段
的主机号：LAN 为 `10.10.10.254/24`、`start=100`、`limit=150` 时，下发给客户端
的是 `10.10.10.100-249`。OpenWrt 默认 `/etc/config/dhcp` 用的是
`192.168.1.100-249`，一旦改 LAN 网段而不改它，客户端就会拿到不可达的地址
（能连上 Wi-Fi/网线但上不了网）。本仓库的 `/etc/config/dhcp` 由 build.sh
渲染，会自动跟随 LAN 网段。

### 只挂了一块网卡怎么办

`/etc/uci-defaults/99-pve-defaults` 在首次启动时会检查：若 `eth1` 不存在，
自动把 `eth0` 挪进 `br-lan` 并把 `wan`/`wan6` 置为 `none`，退化成单网卡模式，
至少还能进 LuCI 改配置 —— 而不是彻底失联。

若本来就打算单网卡（旁路由接上游交换机），直接设：

```yaml
build:
  nic_layout: "single"
```

## 为什么会出现"SSH 连不上 / Web 打不开"

历史上这个项目产出过几批这样的固件，原因有三个，各自独立：

### 1. lan 被写死成静态 IP（最常见）

`custom/files/etc/config/network` 曾把 lan 固定为 `192.168.100.1/24`。
如果你的 PVE 网桥是 `192.168.1.0/24`，固件开机后不在你的网段里——
SSH 连不上、Web 打不开，看起来就像"服务没启动"，其实服务都在跑。

现在接口全部由 `config.yml` 渲染，`nic_layout` 决定哪块网卡是 WAN、哪块是 LAN，
地址与掩码都以 CIDR 形式生成（`list ipaddr 10.10.10.254/24`）。
单网卡想走 DHCP 就把 `nic_layout` 设为 `single` 并给 lan 配 `dhcp`。

### 2. root 无密码时 dropbear 拒绝密码登录

OpenWrt 默认 root 没有密码，而 dropbear 的密码认证在有密码时才可用。
没密码 → 所有密码登录被拒 → 同样表现为"SSH 服务没有"。

现在 `build.root_password: "root"` 会在首次启动时通过
`/etc/uci-defaults/99-pve-defaults` 设置密码。**登录后请立刻 `passwd` 修改。**

### 3. LuCI / uhttpd 被 defconfig 静默丢弃

`CONFIG_PACKAGE_luci=y` 只是"请求"。如果 feeds 没装完整（luci feed 缺失），
kconfig 会把 luci 和它依赖的 uhttpd 一起丢掉，构建依然"成功"，
产出的固件没有 Web 服务器。

现在 build.sh 有两道保险：
- 显式选中 `dropbear` / `luci` / `uhttpd` / `uhttpd-mod-ubus`，
  不再依赖 `DEFAULT_PACKAGES`；
- `verify_critical_packages()` 在 `make defconfig` 之后硬断言这些符号确实
  以 `=y/=m` 存在，否则**构建直接失败**，不再发出残废固件。

## 开机后怎么找到设备

1. **看控制台**：PVE 里打开该 VM 的 Console（x86 镜像默认在 `ttyS0` 有输出），
   登录后 `ip -4 addr show br-lan` 看拿到的地址。
2. **DHCP 租约**：在你的上游路由器/DHCP 服务器上找主机名
   `immortalwrt-pve`（可用 `build.hostname` 修改）。
3. **改成你的网段**：编辑 `config.yml` 的 `build.*`，例如：

   ```yaml
   build:
     nic_layout: "router"
     wan_mode: "static"
     wan_ip: "192.168.60.253"
     wan_netmask: "255.255.255.0"
     wan_gateway: "192.168.60.254"
     wan_dns: ["192.168.60.254", "223.5.5.5"]
     lan_ip: "10.10.10.254"
     lan_netmask: "255.255.255.0"
     lan_dhcp_start: "100"
     lan_dhcp_limit: "150"
   ```

   WAN 的 gateway/dns 只在非空时写入，不会产生 `option gateway ''` 这类脏配置；
   多个 DNS 会渲染成多条 `list dns`。

## 验证固件里到底装了什么

镜像目录里 OpenWrt 会生成 `*.manifest`，逐行列出实际装进 rootfs 的每个包。
build.sh 会把它复制成 `dist/package-manifest.txt` 并打印统计，例如：

```
[INFO] rootfs 内实际安装包数量: 187
[INFO]   [有] dropbear
[INFO]   [有] uhttpd
[INFO]   [有] luci-base
```

如果看到 `[缺]`，说明该固件的对应服务确实不存在，看上面的第 3 条。

## 排查清单

```bash
service dropbear status      # 是否在跑
service uhttpd status
netstat -lntp | grep -E ':(22|80|443)'   # 端口是否监听
uci show network.lan        # 当前 lan 配置
uci show dropbear           # 密码认证是否开启
logread | tail -50
```
