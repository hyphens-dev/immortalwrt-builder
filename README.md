# ImmortalWrt PVE Builder

面向 **PVE / KVM 虚拟机（x86_64）** 优化的 **ImmortalWrt** 自动化构建仓库。
每次 CI 全新浅克隆上游 `immortalwrt/immortalwrt (openwrt-24.10)`，注入本仓库的
内核包、rootfs overlay 与 `.config` 生成逻辑，产出可直接导入 PVE 的
`x86-64-generic-squashfs-combined-efi.img.gz`。

## 交付内容一览

| 类别 | 内容 | 实现方式 |
|------|------|----------|
| VirtIO | virtio-net/-blk/-scsi/-balloon/-rng/-console/-mmio | 已 built-in 于 x86/64 目标内核；额外安装 kmod-virtio-console/balloon/rng |
| **VirtIO-FS** | 挂载 PVE 宿主机共享目录 | 本仓库自带 `package/kernel/linux/modules/fs-virtiofs.mk`（上游 24.10 无此包）+ fuse-utils，详见 [docs/virtiofs.md](docs/virtiofs.md) |
| 9P | 备选主机共享通道 | kmod-fs-9p + kmod-virtio-9p |
| 网络 | WireGuard、nftables、iptables-nft、bridge/veth/tun | kmod + tools + LuCI app，详见 [docs/networking.md](docs/networking.md) |
| 代理 | **nikki (mihomo)**、SmartDNS | nikki 需先在 `custom/feeds.conf` 启用 feed（官方 24.10 feeds 不含 mihomo），详见 [docs/nikki.md](docs/nikki.md) |
| 性能 | TCP BBR、Cake、fq_codel、irqbalance | kmod-tcp-bbr / kmod-sched-cake / kmod-sched-fq-codel / irqbalance + `/etc/sysctl.d/900-pve-tuning.conf`，详见 [docs/performance.md](docs/performance.md) |
| LuCI | 浅色主题(bootstrap)、简体中文、统计、防火墙 | luci + luci-theme-bootstrap + luci-i18n-*-zh-cn + luci-app-statistics(collectd) + luci-app-firewall(firewall4/nftables) |

## 快速开始

```bash
git clone https://github.com/YOUR_USERNAME/immortalwrt-pve-builder.git
cd immortalwrt-pve-builder
vim config.yml          # 按需调整功能开关 / LAN IP / 主题
./scripts/build.sh      # 本地一键构建（约需 30GB 磁盘）
# 产物: dist/*.img.gz + dist/manifest.json
```

导入 PVE（详见 [docs/pve-import.md](docs/pve-import.md)）：

```bash
gunzip immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz
qm importdisk <VMID> immortalwrt-*.img local-lvm
# 设备: virtio0(virtio-scsi), net0=virtio,bridge=vmbr0; CPU type=host;
# 可选 hostpci/vhost-user-fs 共享目录给 virtiofs
```

## 目录结构

```
├── config.yml                    # 唯一配置入口（所有脚本/CI 读取它）
├── scripts/
│   ├── build.sh                  # 主构建流程（clone→feeds→dotconfig→make→dist）
│   ├── sync.sh                   # 上游提交检测（--record 记录已构建 commit）
│   ├── utils.sh                  # cfg/cfg_bool/validate_config 公共库
│   └── yq-compatible.mjs         # 确定性 YAML 读取器（替代裸 yq）
├── package/kernel/linux/modules/
│   └── fs-virtiofs.mk        # 自研 virtiofs kmod（上游 24.10 缺失）
├── custom/
│   ├── feeds.conf                # feeds（含 nikki 预留位）
│   └── files/                    # rootfs overlay
│       ├── etc/config/network    # br-lan + @LAN_IP@/@HOSTNAME@ 渲染
│       ├── etc/sysctl.d/900-pve-tuning.conf   # BBR/fq/conntrack 调优
│       ├── etc/hotplug.d/iface/90-virtio-queues # virtio-net 多队列
│       └── etc/rc.local          # BBR insmod 兜底、irqbalance、挂载点
├── tests/parser.test.mjs         # yq 读取器单元测试（node --test）
├── docs/                         # 各特性文档
└── .github/workflows/            # lint / build / sync-upstream / cleanup
```

## CI

| 工作流 | 触发 | 用途 |
|--------|------|------|
| `lint.yml` | PR / push main | shellcheck + actionlint + 解析器单测 |
| `build.yml` | push main、手动、repository_dispatch | 构建固件、缓存 dl/ccache、上传构件、发 Release |
| `sync-upstream.yml` | 每日 02:00 UTC | 检测上游新提交并 dispatch 触发构建 |
| `cleanup.yml` | 每周日 | 清理旧 runs/releases |

要点（如实说明）：

- runner 上有两个互不相关的 `yq`，因此**全部 YAML 解析统一走
  `scripts/yq-compatible.mjs`**（`npm ci && npm test` 覆盖）。
- `sync-upstream.yml` 刻意不把本仓库 rebase 到 ImmortalWrt 之上（无共同历史、
  源码树数 GB）；成功构建的上游 commit 以 `upstream-built-marker` 构件发布，
  绝不推送到 `main`。
- 产物路径是 `bin/targets/x86/64/`（OpenWrt 的 board=x86、subtarget=64），
  **不是** `bin/targets/x86_64/generic/`。
- `kernel.version` 仅为元数据（24.10 x86 固定 6.6）；`-march` 类调优没有
  Kconfig 符号，需改 `include/target.mk`（见 [docs/pve-tuning.md](docs/pve-tuning.md)）。
- `features.proxy.nikki=true` 时若 feed 未提供 mihomo/luci-app-nikki，构建会
  打印警告并跳过该包，而不是失败。

## 测试

```bash
npm ci && npm test                 # 解析器单测
shellcheck scripts/*.sh            # 静态检查
bash -n scripts/build.sh           # 语法自检
```

## License

MIT
