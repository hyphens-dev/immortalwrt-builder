# ImmortalWrt PVE Builder

面向 PVE / KVM 虚拟机（x86_64）优化的 ImmortalWrt 自动化构建。

## 实际交付内容

- **VirtIO 设备** — `virtio-net`、`-blk`、`-scsi`、`-balloon`、`-rng`、
  `-console`、`-mmio`、`-pci` 已直接编译进 x86/64 目标内核。没有
  `kmod-virtio-*` 包，也不需要它。
- **VirtIO-FS** — 上游 24.10 未提供该模块，本仓库额外添加了
  `kmod-fs-virtiofs`（参见 [docs/virtiofs.md](docs/virtiofs.md)）。
- **9p / virtio-9p** — 替代的主机共享传输方式，来自上游软件包。
- **网络** — WireGuard、nftables、bridge/veth/tun。
- **性能** — TCP BBR、Cake、fq_codel、irqbalance。
- **LuCI** — 浅色主题、中文翻译、统计、防火墙。

## 快速开始

```bash
git clone https://github.com/YOUR_USERNAME/immortalwrt-pve-builder.git
cd immortalwrt-pve-builder
# 编辑 config.yml
./scripts/build.sh
```

本地构建要求：Linux、约 30 GB 可用磁盘空间，以及与 CI 相同的依赖包集合
（参见 `.github/workflows/build.yml`）。

## CI

| 工作流 | 触发条件 | 用途 |
|--------|----------|------|
| `lint.yml` | 每个 PR / 推送到 `main` | shellcheck + actionlint + 解析器单元测试（快速反馈 CI 问题） |
| `build.yml` | 推送到 `main`、手动、`workflow_dispatch`、`repository_dispatch` | 构建固件（ccache + dl 缓存）、上传构件、发布 Release |
| `sync-upstream.yml` | 每日 02:00 UTC、手动 | 检测上游新提交并触发 `build.yml` |
| `cleanup.yml` | 每周日 00:00 UTC、手动 | 删除旧的运行记录、构件和 Release |

`sync-upstream.yml` 刻意**不会**将本仓库变基（rebase）到 ImmortalWrt 之上 ——
两个仓库没有共同历史，且源码树有数 GB 之大。每次构建都会全新克隆上游；成功构建
对应的上游提交会作为 `upstream-built-marker` 构件发布（绝不推送到 `main`，
否则会与并发构建产生竞争）。本地运行仍可通过 `scripts/sync.sh --record` 使用
`.upstream-built` 文件。

### CI 中的 YAML 解析

Runner 镜像自带两个互不相关的名为 `yq` 的工具，因此**任何地方都不再直接用裸
`yq` 解析 `config.yml`**。所有工作流和 `scripts/utils.sh` 均使用
`scripts/yq-compatible.mjs` —— 一个由 `package.json`/`package-lock.json`
锁定的确定性 Node.js 读取器（通过 `npm ci` 安装，并由 `npm test` 覆盖测试）。

## 配置

所有配置都在 [`config.yml`](config.yml) 中。以下是关于各项限制的如实说明：

| 选项 | 效果 |
|------|------|
| `source.repo` / `source.branch` / `source.tag` | 构建哪个源码 |
| `target.arch` / `subtarget` / `profile` | 目标三元组 |
| `kernel.version` | **仅为元数据**（24.10 的 x86 固定使用 6.6） |
| `kernel.lto` | 真实生效 — 映射到 `CONFIG_USE_LTO` |
| `kernel.cpu_opt`、`kernel.optimization` | **不生效** — OpenWrt x86 没有 `-march` 符号。参见 [docs/cpu-tuning.md](docs/cpu-tuning.md) |
| `features.virtio.*` | 选择对应的 `kmod-virtio-*` 软件包（驱动也已内建在 x86 内核中） |
| `features.virtiofs.enabled` | 真实生效 — 选择 `kmod-fs-virtiofs` + `kmod-fuse` |
| `features.p9fs.enabled` | 真实生效 |
| `features.network.wireguard` / `.nftables` | 真实生效 |
| `features.performance.*` | 真实生效 |
| `features.proxy.mihomo` | 需要在 `custom/feeds.conf` 中添加额外 feed（24.10 官方源没有） |
| `features.proxy.smartdns` | 真实生效 |
| `features.system.docker` | 真实生效 |
| `packages.include` / `packages.exclude` | 在 `defconfig` 输入之后追加到 `.config` |
| `build.timeout` | 单次尝试超时时间（分钟，默认 330；必须低于 GitHub 任务 360 分钟上限减去克隆/初始化开销） |
| `output.*` | 是**通配符**，不是文件名（镜像带有版本前缀） |

`.config` 按以下顺序组装：

1. `config/x86_64.config` — 目标、镜像类型、分区大小
2. `config/kernel.config` — 仅 `CONFIG_KERNEL_*` 符号
3. `config/packages.config` — `CONFIG_PACKAGE_*` 选择项
4. 来自 `config.yml` 的功能开关
5. `packages.include` / `packages.exclude`
6. `make olddefconfig`（在安装 feeds 之后执行）— kconfig 无法解析的符号会以
   *config drift*（配置漂移）形式报告，而不是被静默丢弃；设置
   `BUILD_STRICT_CONFIG=true` 可在出现任何漂移时让构建失败

## 项目结构

```
.
├── .github/workflows/
│   ├── lint.yml              # shellcheck / actionlint / node 测试
│   ├── build.yml             # 构建 + 发布
│   ├── sync-upstream.yml     # 检测上游，触发构建
│   └── cleanup.yml           # 保留策略清理
├── config/
│   ├── x86_64.config         # 目标 + 镜像选项
│   ├── kernel.config         # 仅 CONFIG_KERNEL_*
│   └── packages.config       # 仅 CONFIG_PACKAGE_*
├── custom/                   # 可选覆盖层（参见 custom/README.md）
│   ├── files/                # rootfs overlay
│   ├── packages/             # 额外软件包源码
│   ├── patches/{kernel,target,pve}/
│   └── feeds.conf            # 额外 feeds
├── package/kernel/linux/modules/
│   └── fs-virtiofs.mk        # kmod-fs-virtiofs（上游没有）
├── scripts/
│   ├── build.sh              # 主入口脚本
│   ├── patch.sh              # 补丁应用
│   ├── sync.sh               # 本地上游检查
│   ├── release.sh            # 本地发布准备
│   ├── utils.sh              # 配置解析、日志、清单
│   └── yq-compatible.mjs     # 确定性 YAML 读取器（替代 `yq`）
├── tests/
│   └── yq-compatible.test.mjs# 解析器冒烟测试（`npm test`）
├── package.json              # 锁定 `yaml` 依赖
├── docs/
│   ├── virtiofs.md
│   ├── cpu-tuning.md
│   └── troubleshooting.md
└── config.yml
```

## PVE 使用方法

1. 下载最新的 Release 资产 `*squashfs-combined.img.gz`。
2. 用 `gunzip` 解压后作为磁盘导入，或直接写入虚拟磁盘。
3. 虚拟机设置：机型 `q35`，BIOS 选 `OVMF`（UEFI）或 `SeaBIOS`，
   磁盘总线选 **VirtIO**，网卡设备选 **VirtIO**。

主机目录共享请参见 [docs/virtiofs.md](docs/virtiofs.md)。

## 诊断

```bash
zcat /proc/config.gz | grep -E 'VIRTIO_FS|TCP_CONG_BBR|9P'
opkg list-installed | grep -E 'virtiofs|9p|wireguard'
sysctl net.ipv4.tcp_congestion_control
```

## 已知限制

- GitHub 的 4 核 / 16 GB runner 在此配置下需要 3–4 小时。任务超时设置为平台
  最大值（360 分钟）。
- OpenWrt 的 `staging_dir`/`tmp` 目录树超过 Actions 缓存 10 GB 上限，因此
  只缓存 `dl/`。
- `mihomo` 无法从官方 feeds 获取。

关于哪些曾经被静默破坏的问题以及现在的处理方式，完整列表见
[docs/troubleshooting.md](docs/troubleshooting.md)。

## 许可证

MIT — 参见 [LICENSE](LICENSE)。

## 致谢

- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [OpenWrt](https://openwrt.org)
- [Proxmox VE](https://www.proxmox.com)
