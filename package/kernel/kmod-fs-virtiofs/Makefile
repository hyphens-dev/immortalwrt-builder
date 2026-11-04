# kmod-fs-virtiofs — VirtIO-FS 客户端内核模块
# ImmortalWrt/OpenWrt openwrt-24.10 上游未提供该 kmod（virtiofs 需要
# CONFIG_VIRTIO_FS 与 CONFIG_FUSE_VMM，即 fs/virtiofs.c），本包补齐。
# 依赖目标内核 6.6+（fs/virtiofs.c 自 5.4 起存在，6.6 完整可用）。

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=kmod-fs-virtiofs
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define KernelPackage/fs-virtiofs
  SUBMENU:=File Systems
  TITLE:=VirtIO-FS client filesystem support
  DEPENDS:=+kmod-fuse @TARGET_x86_64||TARGET_x86
  FILES:= \
	$(LINUX_DIR)/fs/fuse/virtio_fs.ko \
	$(LINUX_DIR)/fs/fuse/fuse.ko
  AUTOLOAD:=$(call AutoProbe,virtio_fs fuse)
  KCONFIG:= \
	CONFIG_FUSE_FS=y \
	CONFIG_VIRTIO_FS=y
endef

define KernelPackage/fs-virtiofs/description
 Kernel module for the VirtIO-FS (virtiofs) client filesystem, used to
 mount host directory shares passed through a vhost-user-fs device
 (e.g. QEMU/PVE `-device vhost-user-fs-pci`). Requires kmod-fuse.
endef

$(eval $(call KernelPackage,fs-virtiofs))
