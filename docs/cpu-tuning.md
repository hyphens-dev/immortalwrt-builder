# CPU tuning (x86-64-v2 / v3)

`kernel.cpu_opt` and `kernel.optimization` in `config.yml` are **informational
only**. OpenWrt's x86 target has no Kconfig symbol for `-march` or `-O2/-O3`
tuning, so `CONFIG_CPU_TYPE="x86-64-v3"` used to be silently discarded by
`make defconfig`.

Two options if you really want tuned code:

## 1. Toolchain flags (whole build)

Add a patch that sets `TARGET_CFLAGS` in `include/target.mk`:

```diff
-TARGET_CFLAGS:=-O2 $(TARGET_CFLAGS_$(ARCH))
+TARGET_CFLAGS:=-O2 -march=x86-64-v3 $(TARGET_CFLAGS_$(ARCH))
```

Place it in `custom/patches/pve/` (applied to the source root). Verify with:

```bash
grep -r 'march=' openwrt/include/target.mk
```

## 2. Per-package flags

```make
# custom/packages/mypkg/Makefile
TARGET_CFLAGS += -march=x86-64-v3
```

## Caveat

`-march=x86-64-v3` requires AVX2. A PVE guest with the default `kvm64` CPU model
does **not** expose AVX2, and the resulting kernel/userspace will crash with
`Illegal instruction`. Either use `-cpu host` (or at least `x86-64-v3` as the
CPU type) in the VM config, or stay on the default `-O2` build.

This is why the default in `config.yml` is `cpu_opt: "none"`.
