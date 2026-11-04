# nikki (mihomo) 旁路由代理

`config.yml` → `features.proxy.nikki`。**如实说明**：mihomo 与 luci-app-nikki
都不在 ImmortalWrt openwrt-24.10 官方 feeds 中，直接开启不会凭空出现该包。

## 启用步骤

1. 编辑 `custom/feeds.conf`，取消注释（或添加）提供 nikki/mihomo 的 feed，例如：

   ```
   src-git nikki https://github.com/jerrykuku/luci-app-nikki.git;main
   ```

   > 请自行确认所选 feed 分支与 openwrt-24.10 / arm64-x86_64 兼容。
   > mihomo 二进制通常由 luci-app-nikki 的 Makefile 通过 source/git URL 拉取，
   > 若构建机无法访问 GitHub Releases，需要镜像源（mirror）。

2. `config.yml` 置 `features.proxy.nikki: true`。

3. 重新运行 `scripts/build.sh`。build.sh 会在安装 feeds 后检测
   `luci-app-nikki|mihomo` 是否存在：
   - 存在 → `.config` 追加 `CONFIG_PACKAGE_mihomo=y`、`CONFIG_PACKAGE_luci-app-nikki=y`
   - 不存在 → 打印 WARN 并跳过（构建不失败）

## 运行时

```sh
service nikki start        # procd 服务名以 feed 为准（nikki/mihomo）
netstat -lntp | grep -E '7890|9090'
curl -s http://127.0.0.1:9090/version   # mihomo external-controller
```

LuCI: 服务 → Nikki，配置订阅、端口；面板可选 metacubexd/zashboard。

## 与 nftables 协同

- mihomo TPROXY/tun 模式依赖本镜像已装的 `kmod-nft-tproxy`、`kmod-tun`。
- tun 模式建议 `features.network.tun: true`（默认已开）。
- SmartDNS 可与 nikki 共存：SmartDNS 5335 上游，nikki 接管 53（feed 文档内说明）。
