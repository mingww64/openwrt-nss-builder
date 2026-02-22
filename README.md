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

## 🤖 CI/CD Supercharged

Fully automated GitHub Actions pipeline included out-of-the-box:

- 📡 **Upstream Sync**: Checks OpenWrt `main-nss` every 6 hours. Builds only when there's new code.
- ⚡ **Smart Caching**: Persists `dl/`, `.ccache/`, and uses `magic-nix-cache` for lightning-fast rebuilds.
- 📦 **Auto-Releases**: Successful builds automatically publish firmware images (`*.bin`, `*.itb`) to GitHub Releases.
- 🐛 **Debug-Ready**: Build fails? All `*.log` files are instantly uploaded as artifacts, and an interactive SSH session is launched for live debugging.
