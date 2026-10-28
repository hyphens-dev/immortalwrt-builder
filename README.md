# ImmortalWrt PVE Builder

Automated firmware build system for ImmortalWrt optimized for PVE/KVM virtualization.

## Features

- **PVE/KVM Optimized**: VirtIO drivers (net, block, scsi, balloon, rng, console, input, mmio)
- **VirtIO-FS Support**: Mount PVE host shares directly in guest
- **9P Filesystem**: Alternative host-guest file sharing
- **Side Router Ready**: WireGuard, nftables, SmartDNS, Mihomo (Clash Meta)
- **Performance Tuned**: BBR, fq_codel, Cake, IRQ balance, x86-64-v3 optimization
- **Auto CI/CD**: GitHub Actions for automated builds and releases

## Quick Start

### 1. Fork/Clone Repository

```bash
git clone https://github.com/YOUR_USERNAME/immortalwrt-pve-builder.git
cd immortalwrt-pve-builder
```

### 2. Configure Build

Edit `config.yml`:

```yaml
source:
  repo: "https://github.com/immortalwrt/immortalwrt.git"
  branch: "openwrt-24.10"

target:
  arch: "x86_64"

features:
  virtiofs:
    enabled: true
  network:
    wireguard: true
    nftables: true
  proxy:
    mihomo: true
```

### 3. Trigger Build

**Manual:**
- Go to Actions → Build ImmortalWrt PVE Firmware → Run workflow

**Automatic:**
- Daily check for upstream updates
- Auto-build on new commits

### 4. Download Firmware

- Go to Releases → Download latest firmware
- Files: `firmware.img.gz`, `rootfs.tar.gz`, `kernel.bin`

## Project Structure

```
immortalwrt-pve-builder/
├── .github/workflows/
│   ├── build.yml           # Main build workflow
│   ├── sync-upstream.yml   # Upstream sync workflow
│   ├── release.yml         # Release workflow
│   └── cleanup.yml         # Cleanup workflow
├── config/
│   ├── x86_64.config       # Base target config
│   ├── kernel.config       # Kernel options (VirtIO, BBR, etc.)
│   └── packages.config     # Package selection
├── patches/
│   ├── kernel/             # Linux kernel patches
│   ├── target/             # Target system patches
│   └── pve/                # PVE-specific patches
├── scripts/
│   ├── build.sh            # Main build script
│   ├── patch.sh            # Patch application
│   ├── sync.sh             # Upstream sync
│   ├── release.sh          # Release preparation
│   └── utils.sh            # Utility functions
├── files/                  # Custom files overlay
├── config.yml              # Main configuration
└── README.md
```

## Configuration

### config.yml Options

| Option | Description | Default |
|--------|-------------|---------|
| `source.repo` | ImmortalWrt repository | `https://github.com/immortalwrt/immortalwrt.git` |
| `source.branch` | Branch to build | `openwrt-24.10` |
| `target.arch` | Target architecture | `x86_64` |
| `kernel.version` | Kernel version | `6.12` |
| `kernel.cpu_opt` | CPU optimization | `x86-64-v3` |
| `features.virtiofs.enabled` | VirtIO-FS support | `true` |
| `features.network.wireguard` | WireGuard VPN | `true` |
| `features.proxy.mihomo` | Mihomo (Clash Meta) | `true` |
| `features.performance.bbr` | BBR congestion control | `true` |
| `release.keep_releases` | Keep last N releases | `30` |

### Feature Toggles

```yaml
features:
  virtio:
    enabled: true
    net: true
    block: true
    scsi: true
    balloon: true
    rng: true
    console: true
    input: true
    mmio: true

  virtiofs:
    enabled: true
    fuse: true

  p9fs:
    enabled: true

  network:
    wireguard: true
    nftables: true
    iptables_nft: true
    bridge: true
    multi_wan: true

  proxy:
    mihomo: true
    smartdns: true
    adguardhome: false

  system:
    docker: false
    luci: true
    luci_cn: true

  performance:
    bbr: true
    fq_codel: true
    cake: true
    irq_balance: true
```

## PVE Usage

### Install Firmware

1. Download `firmware.img.gz` from Releases
2. Create VM in PVE with:
   - OS: "Do not use any media"
   - Disk: Import firmware as disk
   - Network: VirtIO (paravirtualized)
   - Machine: q35
   - BIOS: OVMF (UEFI) or SeaBIOS

### Enable VirtIO-FS

1. In PVE VM options, add shared memory:
   ```
   args: -object memory-backend-memfd,id=mem,size=1G,share=on -numa node,memdev=mem
   ```

2. Add VirtIO-FS device:
   ```
   hostpci0: virtiofs
   ```

3. In ImmortalWrt guest:
   ```bash
   mkdir -p /mnt/shared
   mount -t virtiofs shared /mnt/shared
   ```

### Enable 9P Filesystem

1. In PVE VM config:
   ```
   args: -fsdev local,id=fsdev0,path=/path/to/share,security_model=passthrough -device virtio-9p-pci,fsdev=fsdev0,mount_tag=hostshare
   ```

2. In ImmortalWrt guest:
   ```bash
   mkdir -p /mnt/host
   mount -t 9p -o trans=virtio hostshare /mnt/host
   ```

## Customization

### Add Custom Patches

Place `.patch` files in:
- `patches/kernel/` - Linux kernel patches
- `patches/target/` - Target system patches
- `patches/pve/` - PVE-specific patches

### Add Custom Packages

Edit `config/packages.config`:
```
CONFIG_PACKAGE_your-package=y
```

### Add Custom Files

Place files in `files/` directory to overlay onto firmware root.

## Workflows

### build.yml
- Manual trigger or called by sync
- Compiles firmware with all optimizations
- Uploads artifacts

### sync-upstream.yml
- Daily cron schedule
- Checks for ImmortalWrt updates
- Triggers build if updates found

### release.yml
- Creates GitHub Release
- Uploads firmware artifacts
- Generates changelog

### cleanup.yml
- Weekly cleanup
- Removes old artifacts
- Keeps last N releases

## Troubleshooting

### Build Fails

1. Check build logs in Actions
2. Verify `config.yml` syntax
3. Check patch compatibility

### VirtIO-FS Not Working

1. Verify kernel config:
   ```bash
   zcat /proc/config.gz | grep VIRTIO_FS
   ```
2. Check PVE VM configuration
3. Verify memory backend is configured

### Network Issues

1. Check nftables rules:
   ```bash
   nft list ruleset
   ```
2. Verify WireGuard config:
   ```bash
   wg show
   ```

## Contributing

1. Fork repository
2. Create feature branch
3. Commit changes
4. Push to branch
5. Create Pull Request

## License

MIT License - See LICENSE file

## Credits

- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [OpenWrt](https://openwrt.org)
- [PVE](https://pve.proxmox.com)
