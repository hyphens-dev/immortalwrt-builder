# ImmortalWrt PVE Builder

Automated ImmortalWrt builds tuned for PVE / KVM guests (x86_64).

## What you actually get

- **VirtIO devices** — `virtio-net`, `-blk`, `-scsi`, `-balloon`, `-rng`,
  `-console`, `-mmio`, `-pci` are compiled into the x86/64 target kernel. There
  is no `kmod-virtio-*` package and none is needed.
- **VirtIO-FS** — upstream 24.10 does not ship this module, so this repo adds
  `kmod-fs-virtiofs` (see [docs/virtiofs.md](docs/virtiofs.md)).
- **9p / virtio-9p** — the alternative host-share transport, from upstream
  packages.
- **Networking** — WireGuard, nftables, bridge/veth/tun.
- **Performance** — TCP BBR, Cake, fq_codel, irqbalance.
- **LuCI** — light theme, Chinese translation, statistics, firewall.

## Quick start

```bash
git clone https://github.com/YOUR_USERNAME/immortalwrt-pve-builder.git
cd immortalwrt-pve-builder
# edit config.yml
./scripts/build.sh
```

Requirements for a local build: Linux, ~30 GB free disk, the same package set the
CI installs (see `.github/workflows/build.yml`).

## CI

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `lint.yml` | every PR / push to `main` | shellcheck + actionlint + parser unit tests (fast CI-sanity feedback) |
| `build.yml` | push to `main`, manual, `workflow_dispatch`, `repository_dispatch` | Builds firmware (ccache + dl caches), uploads artifacts, publishes a release |
| `sync-upstream.yml` | daily 02:00 UTC, manual | Detects new upstream commits and triggers `build.yml` |
| `cleanup.yml` | weekly Sunday 00:00 UTC, manual | Deletes old runs, artifacts and releases |

`sync-upstream.yml` deliberately does **not** rebase this repository onto
ImmortalWrt — the two repos share no history and the source tree is several
gigabytes. Each build clones upstream fresh; the successfully-built upstream
commit is published as the `upstream-built-marker` artifact (never pushed to
`main`, which would race with concurrent builds). Local runs may still use
`.upstream-built` via `scripts/sync.sh --record`.

### YAML parsing in CI

The runner image ships two unrelated tools named `yq`, so **nothing parses
`config.yml` with bare `yq` anymore**. All workflows and `scripts/utils.sh`
use `scripts/yq-compatible.mjs` — a deterministic Node.js reader pinned by
`package.json`/`package-lock.json` (`npm ci` installs it; covered by
`npm test`).

## Configuration

Everything lives in [`config.yml`](config.yml). Honest notes about the limits:

| Option | Effect |
|--------|--------|
| `source.repo` / `source.branch` / `source.tag` | What to build |
| `target.arch` / `subtarget` / `profile` | Target triple |
| `kernel.version` | **Metadata only** (24.10 ships 6.6 for x86) |
| `kernel.lto` | Real — maps to `CONFIG_USE_LTO` |
| `kernel.cpu_opt`, `kernel.optimization` | **Not applied** — OpenWrt x86 has no `-march` symbol. See [docs/cpu-tuning.md](docs/cpu-tuning.md) |
| `features.virtio.*` | Selects matching `kmod-virtio-*` packages (drivers are also built into the x86 kernel) |
| `features.virtiofs.enabled` | Real — selects `kmod-fs-virtiofs` + `kmod-fuse` |
| `features.p9fs.enabled` | Real |
| `features.network.wireguard` / `.nftables` | Real |
| `features.performance.*` | Real |
| `features.proxy.mihomo` | Needs an extra feed in `custom/feeds.conf` (not in 24.10) |
| `features.proxy.smartdns` | Real |
| `features.system.docker` | Real |
| `packages.include` / `packages.exclude` | Appended to `.config` after `defconfig` inputs |
| `build.timeout` | Per-attempt timeout, minutes (default 330; must stay below the 360-minute GitHub job cap minus clone/setup overhead) |
| `output.*` | **Globs**, not file names (images are version-prefixed) |

`.config` is assembled in this order:

1. `config/x86_64.config` — target, image types, partition sizes
2. `config/kernel.config` — `CONFIG_KERNEL_*` symbols only
3. `config/packages.config` — `CONFIG_PACKAGE_*` selections
4. Feature toggles from `config.yml`
5. `packages.include` / `packages.exclude`
6. `make olddefconfig` (after feeds are installed) — symbols that kconfig
   cannot resolve are reported as *config drift* instead of being silently
   dropped; set `BUILD_STRICT_CONFIG=true` to fail the build on any drift

## Project layout

```
.
├── .github/workflows/
│   ├── lint.yml              # shellcheck / actionlint / node tests
│   ├── build.yml             # build + release
│   ├── sync-upstream.yml     # detect upstream, trigger build
│   └── cleanup.yml           # retention
├── config/
│   ├── x86_64.config         # target + image options
│   ├── kernel.config         # CONFIG_KERNEL_* only
│   └── packages.config       # CONFIG_PACKAGE_* only
├── custom/                   # optional overlays (see custom/README.md)
│   ├── files/                # rootfs overlay
│   ├── packages/             # extra package sources
│   ├── patches/{kernel,target,pve}/
│   └── feeds.conf            # extra feeds
├── package/kernel/linux/modules/
│   └── fs-virtiofs.mk        # kmod-fs-virtiofs (not in upstream)
├── scripts/
│   ├── build.sh              # main entrypoint
│   ├── patch.sh              # patch application
│   ├── sync.sh               # local upstream check
│   ├── release.sh            # local release prep
│   ├── utils.sh              # config parsing, logging, manifest
│   └── yq-compatible.mjs     # deterministic YAML reader (replaces `yq`)
├── tests/
│   └── yq-compatible.test.mjs# parser smoke tests (`npm test`)
├── package.json              # pins the `yaml` dependency
├── docs/
│   ├── virtiofs.md
│   ├── cpu-tuning.md
│   └── troubleshooting.md
└── config.yml
```

## PVE usage

1. Download the newest release asset `*squashfs-combined.img.gz`.
2. `gunzip` it and import as a disk, or write it to a virtual disk.
3. VM settings: machine `q35`, BIOS `OVMF` (UEFI) or `SeaBIOS`,
   disk bus **VirtIO**, network device **VirtIO**.

For host directory sharing see [docs/virtiofs.md](docs/virtiofs.md).

## Diagnostics

```bash
zcat /proc/config.gz | grep -E 'VIRTIO_FS|TCP_CONG_BBR|9P'
opkg list-installed | grep -E 'virtiofs|9p|wireguard'
sysctl net.ipv4.tcp_congestion_control
```

## Known limits

- GitHub's 4-core / 16 GB runners take 3-4 h for this configuration. The job
  timeout is set to the platform maximum (360 min).
- The OpenWrt `staging_dir`/`tmp` trees exceed the 10 GB Actions cache limit, so
  only `dl/` is cached.
- `mihomo` is not available from the official feeds.

See [docs/troubleshooting.md](docs/troubleshooting.md) for the full list of
things that were silently broken and how they are now handled.

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [OpenWrt](https://openwrt.org)
- [Proxmox VE](https://www.proxmox.com)