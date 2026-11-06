# kmod-fs-virtiofs — VirtIO-FS 客户端内核模块
# ImmortalWrt/OpenWrt openwrt-24.10 上游未提供该 kmod，本包补齐。
#
# 内核事实核对（Linux 6.6，fs/fuse/Makefile）：
#   obj-$(CONFIG_FUSE_FS)    += fuse.o
#   obj-$(CONFIG_VIRTIO_FS)  += virtiofs.o        <- 模块名是 virtiofs.ko
#   virtiofs-y := virtio_fs.o                     <- 源文件名才是 virtio_fs.o
# 所以 FILES 必须写 fs/fuse/virtiofs.ko，写 virtio_fs.ko 会在 make 阶段
# 报 "No such file or directory" 并中断整个构建。
#
# fuse.ko 由上游 kmod-fuse（package/kernel/linux/modules/fs.mk）提供，
# 这里只依赖它，不再重复声明，否则两个包会安装同一个 .ko。
#
# 依赖：CONFIG_VIRTIO_FS 依赖 FUSE_FS 并 select VIRTIO（见 fs/fuse/Kconfig）。

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=kmod-fs-virtiofs
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define KernelPackage/fs-virtiofs
  SUBMENU:=$(FS_MENU)
  TITLE:=VirtIO-FS client filesystem support
  DEPENDS:=+kmod-fuse @TARGET_x86_64||TARGET_x86
  FILES:= \
	$(LINUX_DIR)/fs/fuse/virtiofs.ko
  AUTOLOAD:=$(call AutoLoad,81,virtiofs)
  KCONFIG:= \
	CONFIG_VIRTIO_FS
endef

define KernelPackage/fs-virtiofs/description
  Kernel module for the VirtIO-FS (virtiofs) client filesystem, used to
  mount host directory shares passed through a vhost-user-fs device
  (e.g. QEMU/PVE `-device vhost-user-fs-pci`). Requires kmod-fuse.
endef

$(eval $(call KernelPackage,fs-virtiofs))
