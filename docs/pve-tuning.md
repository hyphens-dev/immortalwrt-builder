# CPU / 编译调优的如实说明

## config.yml 中 kernel.cpu_opt / kernel.optimization

OpenWrt/ImmortalWrt 的 x86 target **没有** `-march`/`-mtune`/`-O3` 的 Kconfig
符号，这两个键仅作意图记录；`scripts/build.sh` 不会把它们写进 `.config`。

## 真正生效的调优路径

1. **target.mk 级（影响全部用户态包）**
   `include/target.mk` 中 x86/64 使用 `-march=x86-64 -mtune=generic`。
   若 VM 固定跑在已知代次的宿主上，可 patch：

   ```bash
   # 在 build.sh 注入 overlay 之前追加类似逻辑（示意）：
   sed -i 's/-march=x86-64 -mtune=generic/-march=native -O2/' include/target.mk
   ```

   代价：产物不再兼容老 CPU，官方源 ipk 混装会 SIGILL。CI 构件需注明基线。

2. **内核级**
   `Kernel/PVE` 场景收益最大的是内核自带 CONFIG_MITIGATIONS=n（关 Spectre
   缓解）——安全换性能，需要自行评估：

   ```
   # .config 追加
   CONFIG_X86_PAE=n        # 64 位无关，忽略
   # OpenWrt 无直接开关时，可在 GRUB/kernel cmdline: mitigations=off
   ```

   PVE guest 更推荐在 VM 配置层面处理（CPU type=host + 可信宿主）。

3. **LTO**
   `kernel.lto: on` → `CONFIG_USE_LTO=y`，构建时间显著变长，体积略降。

4. **运行时调优（默认已做）**
   `/etc/sysctl.d/900-pve-tuning.conf`、virtio-net 多队列 hotplug、irqbalance
   —— 见 [performance.md](performance.md)。这些不动 toolchain，风险最低。

## 建议

保持 x86-64-v2/v3 基线（PVE `cpu host` + ImmortalWrt 默认 generic 即可吃满
绝大多数虚拟化收益），把精力放在 qdisc/BBR/队列数上；只有当瓶颈确认为压缩、
加密类用户态负载时，才考虑 `-march` 重编。
