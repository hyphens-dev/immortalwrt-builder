# SPDX-License-Identifier: GPL-2.0-only
#
# VirtIO-FS support for ImmortalWrt/OpenWrt.
#
# Upstream 24.10 ships no kmod-fs-virtiofs package, so this file adds one. It is
# installed into the source tree by scripts/build.sh (package/kernel/linux/
# modules/ is globbed by package/kernel/linux/Makefile:76).
#
# Notes:
#  * No dependency on a non-existent VIRTIO_SUPPORT symbol - the virtio core is
#    already built into the x86/64 target kernel.
#  * Only symbols that exist in Linux 6.6 are listed. CONFIG_FUSE_PASSTHROUGH /
#    CONFIG_FUSE_IO_URING are >= 6.9, CONFIG_FUSE_VIRTIO_FS does not exist at
#    all (virtiofs lives in fs/fuse/ and is gated by CONFIG_VIRTIO_FS).
#  * virtiofs.ko is built into fs/fuse/ since kernel 5.10.

define KernelPackage/fs-virtiofs
  SUBMENU:=$(FS_MENU)
  TITLE:=VirtIO Filesystem support
  DEPENDS:=+kmod-fuse
  KCONFIG:= \
    CONFIG_VIRTIO_FS \
    CONFIG_FUSE_DAX=n
  FILES:= \
    $(LINUX_DIR)/fs/fuse/virtiofs.ko
  AUTOLOAD:=$(call AutoLoad,81,virtiofs)
endef

define KernelPackage/fs-virtiofs/description
  Kernel module for VirtIO Filesystem (virtiofs) support.
  Enables mounting host directories shared via a VirtIO-FS device, as
  provided by PVE/KVM (virtiofsd).
endef

$(eval $(call KernelPackage,fs-virtiofs))
