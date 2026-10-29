# Troubleshooting

## Build fails at "Install build dependencies"

Ubuntu 24.04 (noble) **does not have** `python3-distutils`, `libncurses5-dev`
or `ecj`. The workflow installs `libncurses-dev`, `python3-setuptools` and
`default-jdk` instead.

## Build fails at "Apply patches"

`scripts/patch.sh` exits non-zero when a patch does not apply; it no longer
pretends success. Check the log for the failing file name, then either update
the patch or move it out of `custom/patches/`.

Patches already applied are detected (`git apply --reverse --check`) and
skipped, so re-running is safe.

## `CONFIG_PACKAGE_...` warnings during `make defconfig`

A package symbol that does not exist in any enabled feed is dropped. Verify the
exact name against the feed:

```bash
./scripts/feeds list -r <substring>
```

Known pitfalls for this project (all fixed, listed so they do not regress):

| Wrong | Right |
|-------|-------|
| `kmod-virtio-net` | *(built into the x86/64 kernel, no package)* |
| `kmod-nftables` | `kmod-nft-core`, `kmod-nft-nat`, `kmod-nft-fib` |
| `nftables` | `nftables-json` (provides `nftables`) |
| `kmod-9pnet-virtio` | `kmod-9pvirtio` |
| `kmod-sched-fq-codel` | `kmod-sched-core` (fq_codel lives there) |
| `kmod-bridge` | *(CONFIG_BRIDGE=y in the generic kernel config)* |
| `mihomo` | not in the 24.10 feeds - needs `custom/feeds.conf` |
| `lspci` / `lsusb` | binaries from `pciutils` / `usbutils` |

## `sha256sum -c sha256sums.txt` reports a mismatch

The checksum file used to hash itself. It is now generated with the output file
excluded (`-not -name "$out_name"`), and CI generates it with
`find ... ! -name 'sha256sums.txt'`.

## Artifacts are empty

Image names are versioned, e.g.
`openwrt-24.10.0-x86-64-generic-squashfs-combined.img.gz`. Collection uses the
globs from `output.*` in `config.yml`, not exact file names.

## Build times out

A full x86_64 + LuCI build needs roughly 3-4 h on a 4-core runner. `build.timeout`
defaults to 350 minutes; GitHub's hard per-job limit is 360.
