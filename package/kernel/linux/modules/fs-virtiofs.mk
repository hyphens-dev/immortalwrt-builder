# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2024 ImmortalWrt Project
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

define KernelPackage/fs-virtiofs
  SUBMENU:=$(FS_MENU)
  TITLE:=VirtIO Filesystem support
  DEPENDS:=+kmod-fuse @VIRTIO_SUPPORT
  KCONFIG:= \
    CONFIG_VIRTIO_FS \
    CONFIG_FUSE_DAX=n \
    CONFIG_FUSE_PASSTHROUGH=n \
    CONFIG_FUSE_IO_URING=n
  FILES:= \
    $(LINUX_DIR)/fs/fuse/virtiofs.ko
  AUTOLOAD:=$(call AutoLoad,81,virtiofs)
endef

define KernelPackage/fs-virtiofs/description
  Kernel module for VirtIO Filesystem (virtiofs) support.
  This enables mounting host directories shared via VirtIO-FS
  shared filesystem from PVE/KVM hypervisors.
endef

$(eval $(call KernelPackage,fs-virtiofs))
