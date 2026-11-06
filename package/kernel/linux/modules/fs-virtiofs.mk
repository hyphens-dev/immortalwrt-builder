#
# VirtIO-FS (virtiofs) client kernel module.
#
# Upstream openwrt-24.10 does not ship this kmod: the generic kernel config
# has "# CONFIG_VIRTIO_FS is not set" and no KernelPackage declares it.
#
# This file is a FRAGMENT, not a standalone package: package/kernel/linux/
# Makefile does `include $(sort $(wildcard ./modules/*.mk))`, so it is
# evaluated inside the `kernel` package's context. It must therefore contain
# only `define KernelPackage/...` blocks - no `include rules.mk`, no
# `PKG_NAME`, no `include package.mk`. Adding those overrides the kernel
# package's own PKG_NAME/PKG_BUILD_DIR and produces build rules pointing at
# build_dir/.../linux-x86_64/packages, which is an empty directory without a
# Makefile ("No targets specified and no makefile found").
#
# Kernel facts (Linux 6.6, fs/fuse/Makefile):
#   obj-$(CONFIG_FUSE_FS)   += fuse.o
#   obj-$(CONFIG_VIRTIO_FS) += virtiofs.o     <- module is virtiofs.ko
#   virtiofs-y := virtio_fs.o                 <- that is the *source* file
# so FILES must name fs/fuse/virtiofs.ko. fuse.ko itself is provided by
# upstream kmod-fuse, so it is not repeated here.
#
# SUBMENU is spelled out instead of $(FS_MENU) because `sort` places
# "fs-virtiofs.mk" before "fs.mk" ('-' 0x2D < '.' 0x2E), i.e. before
# FS_MENU is defined.
#
# fs/fuse/Kconfig: VIRTIO_FS depends on FUSE_FS and selects VIRTIO, both of
# which are already satisfied (kmod-fuse pulls FUSE_FS, virtio is built into
# the x86/64 target kernel).

define KernelPackage/fs-virtiofs
  SUBMENU:=Filesystems
  TITLE:=VirtIO-FS client filesystem support
  DEPENDS:=+kmod-fuse
  KCONFIG:= \
	CONFIG_VIRTIO_FS
  FILES:= \
	$(LINUX_DIR)/fs/fuse/virtiofs.ko
  AUTOLOAD:=$(call AutoLoad,81,virtiofs)
endef

define KernelPackage/fs-virtiofs/description
  Kernel module for the VirtIO-FS (virtiofs) client filesystem, used to
  mount host directory shares passed through a vhost-user-fs device
  (e.g. QEMU/PVE `-device vhost-user-fs-pci`). Requires kmod-fuse.
endef

$(eval $(call KernelPackage,fs-virtiofs))
