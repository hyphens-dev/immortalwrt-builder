# 首次开机：SSH 与 Web 界面

## 为什么会出现"SSH 连不上 / Web 打不开"

历史上这个项目产出过几批这样的固件，原因有三个，各自独立：

### 1. lan 被写死成静态 IP（最常见）

`custom/files/etc/config/network` 曾把 lan 固定为 `192.168.100.1/24`。
如果你的 PVE 网桥是 `192.168.1.0/24`，固件开机后不在你的网段里——
SSH 连不上、Web 打不开，看起来就像"服务没启动"，其实服务都在跑。

现在默认 `build.net_mode: "dhcp"`，接上 PVE 网桥就能从上游 DHCP 拿到地址。

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
3. **改回静态**：编辑 `config.yml`：

   ```yaml
   build:
     net_mode: "static"
     lan_ip: "192.168.100.1"
     lan_netmask: "255.255.255.0"
     lan_gateway: "192.168.100.1"
     lan_dns: "223.5.5.5"
   ```

   静态模式下只写非空的 gateway/dns，不会产生 `option gateway ''` 这类脏配置。

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
