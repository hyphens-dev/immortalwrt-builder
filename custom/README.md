# Custom overlays

Everything in this directory is optional; `scripts/build.sh` skips anything
that is missing or empty.

| Path | Purpose |
|------|---------|
| `files/` | Copied to `<source>/files/` - the standard OpenWrt root filesystem overlay |
| `packages/` | Copied to `<source>/package/custom/` - extra package sources |
| `patches/kernel/` | `*.patch` applied to `<source>/target/linux/x86` |
| `patches/target/` | `*.patch` applied to `<source>/target` |
| `patches/pve/` | `*.patch` applied to `<source>` |
| `feeds.conf` | Extra feed lines appended to `feeds.conf.default` |

## Example: `files/`

```
custom/files/etc/config/network
custom/files/etc/uci-defaults/99-custom
```

## Example: `feeds.conf`

```
src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main
```

Uncommenting the line above is what makes `features.proxy.mihomo: true` in
`config.yml` resolvable, because `mihomo` is not part of the official 24.10
feeds.
