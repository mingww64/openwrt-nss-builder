# OpenWrt NSS Builder 🚀

Build OpenWrt reproducibly in a single command. Powered by Nix.

```bash
nix develop github:mingww64/openwrt-nss-builder --command build-nss-image --profile mr7350
```
*(Pro tip: Append `--refresh` to force Nix to fetch the latest flake updates).*

## 🛠️ Local Overrides (Zero-Clone Setup)
Run remotely, customize locally. Just drop these in your current directory before running the command above:
- 📂 `./patches/` - Apply your own `.patch` files automatically.
- 📝 `./packages.txt` - Define your custom package list.
- ⚙️ `./nss-setup/config-nss.seed` - Provide a custom base configuration.

## 💻 Local Development

Clone the repo and jump right in:

```bash
nix develop  # Or `direnv allow`
build-nss-image --profile mr7350
```

### 🎛️ Build Flags
- `--profile <name>`: Fuzzy search and build a specific device (e.g., `mr7350`, `ipq807x`).
- `--menuconfig`: Fire up the classic `make menuconfig` UI.
- `--make-only`: Skip setup/downloads and jump straight to compilation.
- `--sync-packages`: SSH into a live router and sync its installed packages into your build.

### 🔄 Updating the Flake
When you want to pull the latest upstream OpenWrt commits and feed updates:
1. Run `nix flake update` to fetch the latest inputs.
2. Run `nix develop` — the environment automatically detects changed inputs, **unmounts the old FUSE mounts** (your `build_dir/`, `staging_dir/`, and `.config` are preserved in `.source-upper/`), and remounts the fresh source tree.

> **Want a fully clean rebuild?** Run `clean-nss-mounts` (or `nix run .#clean-nss-mounts` from outside the shell) to wipe all overlay directories including build artefacts, then `nix develop`.

## 🗂️ Filesystem Layer Architecture

Because the Nix store is read-only, the build environment constructs a writable
view of the OpenWrt source tree entirely in userspace using `bindfs` and
`fuse-overlayfs`. No root privileges are required.

```
Nix store (read-only)
 ├── openwrt-source  ──bindfs──►  .source-mapped/          (permission-remapped, still read-only data)
 ├── openwrt-packages ─bindfs──►  .feeds-mapped/packages/
 ├── openwrt-luci ─────bindfs──►  .feeds-mapped/luci/
 ├── openwrt-routing ──bindfs──►  .feeds-mapped/routing/
 ├── nss-packages ─────bindfs──►  .feeds-mapped/nss_packages/
 ├── sqm-scripts-nss ──bindfs──►  .feeds-mapped/sqm_scripts_nss/
 └── luci-theme-argon ─bindfs──►  .feeds-mapped/luci-theme-argon/
                                          │
                                          ▼
                               fuse-overlayfs (per feed)
                               lower:  .feeds-mapped/<name>/
                               upper:  .feeds-upper/<name>/   ← writes land here
                               work:   .feeds-work/<name>/
                                    │
                                    ▼
                              .feeds-merged/<name>/          (fully writable COW view)
                                          │
                              symlinked into
                                          │
                         .source-lower-staging/
                          ├── feeds/
                          │    ├── packages  ──►  .feeds-merged/packages
                          │    ├── luci       ──►  .feeds-merged/luci
                          │    ├── routing    ──►  .feeds-merged/routing
                          │    ├── nss_packages ►  .feeds-merged/nss_packages
                          │    └── sqm_scripts_nss ► .feeds-merged/sqm_scripts_nss
                          └── package/
                               └── luci-theme-argon ► .feeds-merged/luci-theme-argon
                                          │
                              merged as lowerdir alongside
                              .source-mapped  in the root overlay
                                          │
                                          ▼
                               fuse-overlayfs  (root source overlay)
                               lower:  .source-lower-staging : .source-mapped
                               upper:  .source-upper/        ← all other writes land here
                               work:   .source-work/
                                    │
                                    ▼
                                 source/                     (fully writable working tree)
```

**Why two layers per feed?**
`fuse-overlayfs` does not follow symlinks across FUSE boundaries, so simply
symlinking `.source-lower-staging/feeds/<name>` → `.feeds-mapped/<name>` would
expose the read-only bindfs layer. Each feed therefore gets its own
`bindfs` → `fuse-overlayfs` stack, producing `.feeds-merged/<name>` as a fully
writable COW directory. That directory is then symlinked into the root overlay's
lowerdir so it appears naturally at `source/feeds/<name>`.

**Why can't feeds be mounted directly at `source/feeds/<name>`?**
Linux does not permit mounting inside an active FUSE filesystem from the same
user namespace, so `source/feeds/` (which lives inside the root `fuse-overlayfs`)
cannot be used as a mountpoint.

**Cleanup**
Two commands are available depending on what you need:

| Command | Effect |
|---|---|
| `unmount-nss-mounts` / `nix run .#unmount-nss-mounts` | Tears down FUSE mounts only. Build artefacts in `.source-upper/` are **preserved**. Used automatically on flake input change. |
| `clean-nss-mounts` / `nix run .#clean-nss-mounts` | Full wipe: unmounts **and** removes all overlay dirs including `.source-upper/`. Use when you want a clean rebuild from scratch. |

For direnv sessions (where the shell persists between re-entries), mounts are intentionally kept alive — use one of the above commands manually when needed.

## 🤖 CI/CD Supercharged

Fully automated GitHub Actions pipeline included out-of-the-box:

- 📡 **Upstream Sync**: Checks OpenWrt `main-nss` every 6 hours. Builds only when there's new code.
- ⚡ **Smart Caching**: Persists `dl/`, `.ccache/`, and uses `magic-nix-cache` for lightning-fast rebuilds.
- 📦 **Auto-Releases**: Successful builds automatically publish firmware images (`*.bin`, `*.itb`) to GitHub Releases.
- 🐛 **Debug-Ready**: Build fails? All `*.log` files are instantly uploaded as artifacts, and an interactive SSH session is launched for live debugging.
