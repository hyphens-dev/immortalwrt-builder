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

## `make olddefconfig failed ... - the kconfig error output is printed above`

The config step runs `make -j1 V=s defconfig` followed by
`make -j1 V=s olddefconfig` (see `generate_config()` in `scripts/build.sh`).
Serial verbose output means the real kconfig error is printed in the build log
instead of being hidden behind parallel make output, and the failure message
now includes the actual exit code. Since the script *already* passes `-j1 V=s`,
the raw make/kconfig output of each pass is now echoed inline right before the
`[ERROR]` line - scroll up in the CI log instead of rerunning the job.

Two things used to break this step:

1. `.config` was assembled by concatenating `config/*.config` + feature
   toggles, i.e. it had no complete target/subtarget block. Running only
   `olddefconfig` on such a file can fail inside `scripts/config/conf`;
   `defconfig` first bootstraps the full default configuration.
2. Garbage lines written from an empty/whitespace-only `packages.exclude`
   value (wrong `yq` flavour) - see the comment above that loop; the parser
   is now pinned to `scripts/yq-compatible.mjs`.

If the step still fails, re-run locally with:

```bash
cd openwrt && make -j1 V=s defconfig
```

and fix the symbol kconfig reports. Unresolved-but-selected symbols are
reported as *config drift* afterwards; set `BUILD_STRICT_CONFIG=true` to turn
that into a hard failure.

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
