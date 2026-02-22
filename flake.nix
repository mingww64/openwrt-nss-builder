{
  description = "OpenWrt NSS Build Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    openwrt-packages = {
      url = "github:openwrt/packages";
      flake = false;
    };
    openwrt-luci = {
      url = "github:openwrt/luci";
      flake = false;
    };
    openwrt-routing = {
      url = "github:openwrt/routing";
      flake = false;
    };
    nss-packages = {
      url = "github:qosmio/nss-packages/NSS-12.5-K6.x";
      flake = false;
    };
    sqm-scripts-nss = {
      url = "github:qosmio/sqm-scripts-nss";
      flake = false;
    };
    luci-theme-argon = {
      url = "github:jerrykuku/luci-theme-argon";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, openwrt-packages, openwrt-luci, openwrt-routing, nss-packages, sqm-scripts-nss, luci-theme-argon }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};

          routerIp = "192.168.15.1";
          routerUser = "root";

      buildScript = pkgs.writeShellScriptBin "build-nss-image" ''
        set -e
        set -o pipefail
        EXTRA_PACKAGES=$(cat ./packages.txt || echo "")
        if [ "$1" == "--sync-packages" ]; then
          LOGFILE="../build-$(date +%Y%m%d-%H%M%S)-sync.log"
          echo "--- Syncing package list from router using ssh ---" | tee -a "$LOGFILE"

          # Merge static package list and ssh apk info, remove duplicates
          SSH_PACKAGES=$(ssh ${routerUser}@${routerIp} "apk info" | grep -vE '(kmod|kernel|base-files|libc|libgcc|qca-nss|nss-dp|ath11k)')

          EXTRA_PACKAGES=$(echo "$EXTRA_PACKAGES $SSH_PACKAGES" | tr ' ' '\n' | sort -u | tr '\n' ' ')
        else
          LOGFILE="../build-$(date +%Y%m%d-%H%M%S).log"
        fi
        echo -e "--- Including packages: --- \n $EXTRA_PACKAGES \n--- End of package list ---" | tee -a "$LOGFILE"

        LOGFILE="../build-$(date +%Y%m%d-%H%M%S).log"
        # Generate config fragment to enable all packages
        cd source

        if [ "$1" == "--make-only" ]; then
           echo "--- Starting image build (Make only) ---" | tee -a "$LOGFILE"
           make -j$(nproc) V=s PROFILE="linksys_mr7350" 2>&1 | tee -a "$LOGFILE" || {
             echo "Build failed. Check $LOGFILE for details" | tee -a "$LOGFILE"
             exit 1
           }
           echo "--- Build Finished! ---" | tee -a "$LOGFILE"
           exit 0
        fi

        # Install feeds from pinned flake inputs
        echo "--- Installing feeds ---" | tee -a "$LOGFILE"
        ./scripts/feeds update && ./scripts/feeds install -a 2>&1 | tee -a "$LOGFILE"

        # Make all feeds writable since they are copied from read-only Nix store
        chmod -R u+w feeds/

        # Disable Python PGO to prevent test failures during host build
        sed -i 's/--enable-optimizations//g' feeds/packages/lang/python/python3/Makefile

        # Build the image using the config seed
        [ ! -f .config ] && cp nss-setup/config-nss.seed .config
        
        if [ -n "$EXTRA_PACKAGES" ]; then
          for pkg in $EXTRA_PACKAGES; do
            # Only use valid OpenWrt package names
            if [[ $pkg =~ ^[a-zA-Z0-9._+-]+$ ]]; then
              echo "CONFIG_PACKAGE_$pkg=y" >> .config.fragment
            fi
          done
          cat .config.fragment >> .config
          rm -f .config.fragment
        fi
        make defconfig V=s 2>&1 | tee -a "$LOGFILE"

        echo "--- Downloading sources ---" | tee -a "$LOGFILE"
        make download -j$(nproc) V=s 2>&1 | tee -a "$LOGFILE"

        echo "--- Starting image build ---" | tee -a "$LOGFILE"
        make -j$(nproc) V=s PROFILE="linksys_mr7350" 2>&1 | tee -a "$LOGFILE" || {
          echo "Build failed. Check $LOGFILE for details" | tee -a "$LOGFILE"
          exit 1
        }

        echo "--- Build Finished! ---" | tee -a "$LOGFILE"
        echo "Image in source/bin/targets/" | tee -a "$LOGFILE"
      '';

      commonBuildInputs = with pkgs; [
        stdenv.cc binutils patch perl python3 wget git unzip
        libxslt ncurses zlib openssl bc rsync file gnumake gawk
        which diffutils gettext openssh direnv buildScript
        ncurses pkg-config quilt nix-ld ccache
      ];

      commonShellHook = ''
          export NIX_LD="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
          export NIX_LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib"
          export TZ=UTC

          if [ ! -d "source/.git" ]; then
            echo "Cloning OpenWrt source..."
            git clone -b main-nss https://github.com/qosmio/openwrt-ipq.git source
          fi

          if [ -d "cache" ]; then
            echo "Restoring cached directories..."
            cp -r cache/* source/
          fi

          # Apply custom patches
          if [ -d "patches" ]; then
            echo "Applying patches..."
            # For patches that modify the build system (Makefiles, Config.in, etc), apply them at root
            for patch in patches/*.patch; do
              if [ -f "$patch" ]; then
                if patch -d source -R -p1 -s -f --dry-run < "$patch" >/dev/null 2>&1; then
                  echo "✅ Patch $(basename $patch) already applied."
                else
                  echo "🔧 Applying patch $(basename $patch)..."
                  if patch -d source -p1 < "$patch"; then
                    echo "✅ Applied $(basename $patch)"
                  else
                    echo "❌ Failed to apply $(basename $patch)"
                    exit 1
                  fi
                fi
              fi
            done
            
            # For package source patches (e.g. util-linux), copy them to destination
            # This handles structure like patches/package/utils/util-linux/patches/100-...
            if [ -d "patches/package" ]; then
              echo "Copying package patches..."
              cp -r patches/package source/
            fi
            
            # Temporary fix for command_all.sh I/O error in GitHub Actions
            # The script iterates over all PATH entries, which in Nix environment is huge and may contain problematic paths
            # We replace it with a simpler version that returns the command path without iterating manually
            # This avoids the "command: command: I/O error" when hitting problematic directories in PATH
            echo "Patching scripts/command_all.sh to avoid I/O errors..."
            cat > source/scripts/command_all.sh <<'EOF'
#!/bin/sh
# Replaced by flake.nix shellHook to avoid I/O errors in long Nix paths
# Just return the first found command, as we provided the correct env via Nix
command -v "$@"
EOF
            chmod +x source/scripts/command_all.sh
          fi

          # Prepare writable copies of feeds (separate from ./feeds symlink dir)
          if [ ! -d "source/package/luci-theme-argon" ]; then
            cp -r ${luci-theme-argon} source/package/luci-theme-argon
            chmod -R u+w source/package/luci-theme-argon
          fi
          cat > source/feeds.conf.default <<EOF
src-cpy packages ${openwrt-packages}
src-cpy luci ${openwrt-luci}
src-cpy routing ${openwrt-routing}
src-cpy nss_packages ${nss-packages}
src-cpy sqm_scripts_nss ${sqm-scripts-nss}
EOF

          # Automate device selection for MR7350 in config-nss.seed
          sed -i 's/^# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_linksys_mr7350 is not set$/CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_linksys_mr7350=y/' source/nss-setup/config-nss.seed
          sed -i 's/^# CONFIG_TARGET_qualcommax_ipq60xx is not set$/CONFIG_TARGET_qualcommax_ipq60xx=y/' source/nss-setup/config-nss.seed

          sed -i 's/^CONFIG_TARGET_qualcommax_ipq807x=.$/# CONFIG_TARGET_qualcommax_ipq807x is not set/' source/nss-setup/config-nss.seed

          echo "✅ NSS + APK Build Env Active"
          echo "🚀 Run 'build-nss-image' to start."
        '';

    in {
      default = pkgs.mkShell {
        hardeningDisable = [ "format" ];
        buildInputs = commonBuildInputs;
        shellHook = commonShellHook;
      };
    });
  };
}

