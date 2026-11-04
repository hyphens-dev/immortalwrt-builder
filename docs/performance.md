# 性能：BBR / Cake / fq_codel / irqbalance

对应 `config.yml` 的 `features.performance.*`。

## TCP BBR

- 包：`kmod-tcp-bbr`（提供 `tcp_bbr.ko`，内核 6.6 内含 BBRv1）。
- 默认拥塞控制由 rootfs overlay `/etc/sysctl.d/900-pve-tuning.conf` 设置：

```
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
```

- `rc.local` 兜底 `insmod tcp_bbr`，防止首启 AUTOLOAD 竞态。
- 验证：

```sh
sysctl net.ipv4.tcp_congestion_control   # -> bbr
ss -ti | grep -c bbr                       # 有输出即生效
```

BBRv2 (`tcp_bbr2`) 在 6.6 也编译于同一 kmod，可在 sysctl 中改 `bbr2` 试验。

## fq_codel 与 Cake

- OpenWrt 内核默认启用 `DEFAULT_FQ_CODEL=y`，`kmod-sched-fq-codel` 补齐
  sch_fq_codel 模块依赖；`kmod-sched-cake` 提供 cake qdisc。
- 二者用途不同：
  - **fq**：BBR 的最佳拍档（ pacing 队列），用于 WAN 直发。
  - **fq_codel**：通用防缓冲膨胀（bufferbloat）叶子队列。
  - **cake**：整形 + AQM 一体，适合限速场景（配合 `features.performance.sqm`
    打开 sqm-scripts + luci-app-sqm）。
- 手工切换某接口 qdisc：

```sh
tc qdisc replace dev eth0 root cake bandwidth 500mbit
tc qdisc replace dev eth0 root fq_codel
```

## irqbalance

- 包：`irqbalance`，构建后开机自启（procd enable）。
- KVM guest 中主要均衡 virtio 中断（`virtio*` MSI-X 向量）到多 vCPU；
  建议 PVE 侧 VM 至少 2 vCPU 并开启多队列才有意义。
- 验证：`service irqbalance status`、`cat /proc/interrupts | grep virtio`。

## 其它 overlay 调优项（900-pve-tuning.conf）

- socket buffer 上限 26MB、backlog/somaxconn 提升 —— 高带宽代理场景收益明显。
- `busy_poll/busy_read`：低延迟收包（独占核时再考虑加大）。
- `nf_conntrack_max=131072`：nftables 防火墙大并发前提。
- `vm.swappiness=10` + balloon 友好。

## 如实说明

OpenWrt x86 target 没有 `-march=native` 类 Kconfig；若宿主 CPU 较新且想让
用户态程序享受 AVX2 等指令集，需要按 [pve-tuning.md](pve-tuning.md) 修改
`include/target.mk` 自行重编 toolchain，本仓库默认保持可移植 x86-64 基线。
