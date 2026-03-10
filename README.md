# OpenWrt NSS Builder [![OpenWrt NSS Build](https://github.com/mingww64/openwrt-nss-builder/actions/workflows/build.yml/badge.svg)](https://github.com/mingww64/openwrt-nss-builder/actions/workflows/build.yml)

A modern, reproducible OpenWrt build environment powered by **Nix**. No root required.

```bash
nix develop github:mingww64/openwrt-nss-builder --command build-nss-image --profile mr7350
```

## Quick Start

You can run this builder without cloning the repo. To customize, drop these in your current directory:
- 📂 `./patches/` - Auto-applied `.patch` files.
- 📝 `./packages.txt` - Custom package list.[^1]
- ⚙️ `./config.txt` - Extra configuration fragments.[^1]

[^1]: Profile-specific packages and config fragments could be enabled by appending profile name to the file name.
For example, `./packages-mr7350.txt` and `./config-mr7350.txt`.

For local development:
```bash
git clone https://github.com/mingww64/openwrt-nss-builder && cd openwrt-nss-builder
nix develop  # Mounts FUSE environment
build-nss-image --profile mr7350
```
> [!TIP]
> check [config-nss.seed](https://github.com/qosmio/openwrt-ipq/blob/main-nss/nss-setup/config-nss.seed) available profiles.

### Build Flags
- `--profile <name>`: Fuzzy search for device (e.g., `mr7350`, `ipq60xx`).
- `--menuconfig`: Classic `make menuconfig` UI.
- `--sync-packages`: Sync packages from a live router via SSH.

## Lifecycle & Maintenance

The environment uses `fuse-overlayfs` to create a writable view of pinned Nix inputs.

- **Update**: `nix flake update && nix develop` (Detects changes and remounts automatically).
- **Clean Mounts**: `unmount-nss-mounts` (Tears down FUSE, keeps build artifacts).
- **Full Wipe**: `clean-nss-mounts` (Wipes everything for a fresh start).

## CI/CD Highlights

The included GitHub Actions pipeline provides:
- 📡 **Automated Upstream Sync**: Rebuilds only when OpenWrt `main-nss` or feeds change.
- ⚡ **Optimized Builds**: Shared ImageBuilder/SDK per subtarget to save time/storage.
- 📦 **Releases**: Automatic firmware uploads (`.bin`, `.itb`) and ImageBuilder (`.tar.zst`).
- 🐛 **Failure Analysis**: Automatic log uploads and interactive SSH debugging.
