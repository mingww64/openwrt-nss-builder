{
  description = "OpenWrt NSS Build Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    openwrt-source = {
      url = "github:qosmio/openwrt-ipq/main-nss";
      flake = false;
    };
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

  outputs = {
    self,
    nixpkgs,
    openwrt-source,
    openwrt-packages,
    openwrt-luci,
    openwrt-routing,
    nss-packages,
    sqm-scripts-nss,
    luci-theme-argon,
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    nixpkgsFor = forAllSystems (system: import nixpkgs {inherit system;});

    # Shared helper — tears down FUSE mounts only, preserving upper dirs and build artifacts.
    # Used for automatic remounting when flake inputs change.
    makeUnmountScript = pkgs:
      pkgs.writeShellScriptBin "unmount-nss-mounts" ''
        export PATH="${pkgs.fuse-overlayfs}/bin:${pkgs.coreutils}/bin:$PATH"
        echo "Unmounting NSS mounts (build artifacts preserved)..."
        fusermount3 -uz "$PWD/source" 2>/dev/null || true
        fusermount3 -uz "$PWD/.source-mapped" 2>/dev/null || true
        if [ -d .feeds-merged ]; then
          for d in .feeds-merged/*; do
            [ -e "$d" ] && fusermount3 -uz "$PWD/$d" 2>/dev/null || true
          done
        fi
        if [ -d .feeds-mapped ]; then
          for d in .feeds-mapped/*; do
            [ -e "$d" ] && fusermount3 -uz "$PWD/$d" 2>/dev/null || true
          done
        fi
        echo "Done. Run 'nix develop' to remount with the new inputs."
      '';

    # Shared helper — full clean: unmounts AND removes all overlay dirs including build artifacts.
    makeCleanMountsScript = pkgs:
      pkgs.writeShellScriptBin "clean-nss-mounts" ''
        export PATH="${pkgs.fuse-overlayfs}/bin:${pkgs.coreutils}/bin:$PATH"
        echo "Cleaning up mounts..."
        fusermount3 -uz "$PWD/source" 2>/dev/null || true
        fusermount3 -uz "$PWD/.source-mapped" 2>/dev/null || true
        if [ -d .feeds-merged ]; then
          for d in .feeds-merged/*; do
            [ -e "$d" ] && fusermount3 -uz "$PWD/$d" 2>/dev/null || true
          done
        fi
        if [ -d .feeds-mapped ]; then
          for d in .feeds-mapped/*; do
            [ -e "$d" ] && fusermount3 -uz "$PWD/$d" 2>/dev/null || true
          done
        fi
        echo "Removing overlay directories..."
        rm -rf "$PWD/.source-upper" "$PWD/.source-work" "$PWD/.source-mapped" "$PWD/.source-lower-staging" "$PWD/.feeds-mapped" "$PWD/.feeds-merged" "$PWD/.feeds-upper" "$PWD/.feeds-work" "$PWD/source"
        echo "Done. You can now run 'nix flake update' and 'nix develop' to rebuild the environment."
      '';
  in {
    apps = forAllSystems (system: let
      pkgs = nixpkgsFor.${system};
      cleanMountsScript = makeCleanMountsScript pkgs;
      unmountScript = makeUnmountScript pkgs;
    in {
      clean-nss-mounts = {
        type = "app";
        program = "${cleanMountsScript}/bin/clean-nss-mounts";
      };
      unmount-nss-mounts = {
        type = "app";
        program = "${unmountScript}/bin/unmount-nss-mounts";
      };
    });

    devShells = forAllSystems (system: let
      pkgs = nixpkgsFor.${system};

      routerIp = "192.168.15.1";
      routerUser = "root";

      cleanMountsScript = makeCleanMountsScript pkgs;
      unmountScript = makeUnmountScript pkgs;

      buildScript = pkgs.writeShellScriptBin "build-nss-image" ''
        set -e
        if ["$CI" == 1]; then
          set -o pipefail
        fi

        PROFILE="linksys_mr7350"
        SYNC_PACKAGES=0
        MAKE_ONLY=0
        MENUCONFIG=0

        while [[ $# -gt 0 ]]; do
          case $1 in
            --profile)
              PROFILE="$2"
              shift 2
              ;;
            --sync-packages)
              SYNC_PACKAGES=1
              shift
              ;;
            --make-only)
              MAKE_ONLY=1
              shift
              ;;
            --menuconfig)
              MENUCONFIG=1
              shift
              ;;
            *)
              echo "Unknown option: $1"
              exit 1
              ;;
          esac
        done

        EXTRA_PACKAGES=""
        if [ -f ./packages.txt ]; then
          EXTRA_PACKAGES=$(cat ./packages.txt)
        elif [ -f "$FLAKE_SOURCE/packages.txt" ]; then
          EXTRA_PACKAGES=$(cat "$FLAKE_SOURCE/packages.txt")
        fi
        if [ "$SYNC_PACKAGES" -eq 1 ]; then
          LOGFILE="$PWD/build-$(date +%Y%m%d-%H%M%S)-sync.log"
          echo "--- Syncing package list from router using ssh ---" | tee -a "$LOGFILE"

          # Merge static package list and ssh apk info, remove duplicates
          SSH_PACKAGES=$(ssh ${routerUser}@${routerIp} "apk info" | grep -vE '(kmod|kernel|base-files|libc|libgcc|qca-|nss-dp|ath11k|ipq-wifi-)' || true)

          EXTRA_PACKAGES=$(echo "$EXTRA_PACKAGES $SSH_PACKAGES" | tr ' ' '\n' | sort -u | tr '\n' ' ')
        else
          LOGFILE="$PWD/build-$(date +%Y%m%d-%H%M%S).log"
        fi
        echo -e "--- Including packages: --- \n $EXTRA_PACKAGES \n--- End of package list ---" | tee -a "$LOGFILE"

        # Generate config fragment to enable all packages
        cd $PWD/source

        if [ "$MAKE_ONLY" -eq 1 ]; then
           echo "--- Starting image build (Make only) ---" | tee -a "$LOGFILE"
           make -j$(nproc) V=s 2>&1 | tee -a "$LOGFILE" || {
             echo "Build failed. Check $LOGFILE for details" | tee -a "$LOGFILE"
             exit 1
           }
           echo "--- Build Finished! ---" | tee -a "$LOGFILE"
           exit 0
        fi

        if [ "$MENUCONFIG" -eq 1 ]; then
           echo "--- Running make menuconfig ---"
           make menuconfig
           exit 0
        fi

        # Install feeds from pinned flake inputs if they changed
        if [ -f .feeds_need_update ] || [ ! -d feeds ]; then
          echo "--- Installing feeds ---" | tee -a "$LOGFILE"

          ./scripts/feeds update && ./scripts/feeds install -a 2>&1 | tee -a "$LOGFILE"

          # Disable Python PGO to prevent test failures during host build
          sed -i 's/--enable-optimizations//g' feeds/packages/lang/python/python3/Makefile

          rm -f .feeds_need_update
        else
          echo "--- Feeds are up to date, skipping install ---" | tee -a "$LOGFILE"
        fi

        # Build the image using the config seed
        if [ ! -f .config ]; then
          if [ -f nss-setup/config-nss.seed ]; then
            cp nss-setup/config-nss.seed .config
          elif [ -f "$FLAKE_SOURCE/nss-setup/config-nss.seed" ]; then
            cp "$FLAKE_SOURCE/nss-setup/config-nss.seed" .config
          fi
        fi

        # Disable all sub-targets and devices by default in .config
        sed -i 's/^CONFIG_TARGET_qualcommax_\([a-z0-9]*\)=y/# CONFIG_TARGET_qualcommax_\1 is not set/' .config
        sed -i 's/^CONFIG_TARGET_qualcommax_[a-z0-9]*_DEVICE_[a-zA-Z0-9_-]*=y/# & is not set/' .config

        # Fuzzy search for the profile
        MATCHED_PROFILES=$(grep -io "CONFIG_TARGET_qualcommax_[a-z0-9]*_DEVICE_.*$PROFILE.*" .config | sed 's/ is not set//' | sed 's/=y//' | sed 's/^# //' | sort -u || true)

        if [ -z "$MATCHED_PROFILES" ]; then
          echo "❌ Error: Profile '$PROFILE' not found in config-nss.seed" | tee -a "$LOGFILE"
          exit 1
        fi

        MATCH_COUNT=$(echo "$MATCHED_PROFILES" | wc -l)
        if [ "$MATCH_COUNT" -gt 1 ]; then
          echo "⚠️ Multiple profiles matched '$PROFILE':" | tee -a "$LOGFILE"

          # Convert string to array
          mapfile -t PROFILE_ARRAY <<< "$MATCHED_PROFILES"

          # Print options
          for i in "''${!PROFILE_ARRAY[@]}"; do
            echo "  [$((i+1))] ''${PROFILE_ARRAY[$i]}" | tee -a "$LOGFILE"
          done

          # In CI auto-select the first match; otherwise prompt the user
          if [ -n "$CI" ]; then
            echo "CI detected: auto-selecting first match." | tee -a "$LOGFILE"
            MATCHED_PROFILE="''${PROFILE_ARRAY[0]}"
          else
            # Prompt user for choice
            while true; do
              read -p "Select a profile (1-$MATCH_COUNT): " choice
              if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$MATCH_COUNT" ]; then
                MATCHED_PROFILE="''${PROFILE_ARRAY[$((choice-1))]}"
                break
              else
                echo "Invalid selection. Please enter a number between 1 and $MATCH_COUNT."
              fi
            done
          fi
        else
          MATCHED_PROFILE="$MATCHED_PROFILES"
        fi

        SUBTARGET=$(echo "$MATCHED_PROFILE" | sed -E 's/CONFIG_TARGET_qualcommax_([a-z0-9]+)_DEVICE_.*/\1/')

        echo "✅ Found profile: $MATCHED_PROFILE (Subtarget: $SUBTARGET)" | tee -a "$LOGFILE"

        # Enable the matched subtarget and device
        echo "CONFIG_TARGET_qualcommax_$SUBTARGET=y" >> .config.fragment
        echo "$MATCHED_PROFILE=y" >> .config.fragment

        if [ -n "$EXTRA_PACKAGES" ]; then
          for pkg in $EXTRA_PACKAGES; do
            # Only use valid OpenWrt package names
            if [[ $pkg =~ ^[a-zA-Z0-9._+-]+$ ]]; then
              echo "CONFIG_PACKAGE_$pkg=y" >> .config.fragment
            fi
          done
        fi

        cat .config.fragment >> .config
        rm -f .config.fragment

        # Use Nixpkgs Go for bootstrap
        echo "CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=\"$(dirname $(dirname $(which go)))/share/go\"" >> .config
        echo "CONFIG_GOLANG_BUILD_BOOTSTRAP=n" >> .config

        make defconfig V=s 2>&1 | tee -a "$LOGFILE"

        echo "--- Downloading sources ---" | tee -a "$LOGFILE"
        make download -j$(nproc) V=s 2>&1 | tee -a "$LOGFILE"

        echo "--- Starting image build ---" | tee -a "$LOGFILE"
        make -j$(nproc) V=s 2>&1 | tee -a "$LOGFILE" || {
          echo "Build failed. Check $LOGFILE for details" | tee -a "$LOGFILE"
          exit 1
        }

        echo "--- Build Finished! ---" | tee -a "$LOGFILE"
        echo "Image in source/bin/targets/" | tee -a "$LOGFILE"
      '';

      commonBuildInputs = with pkgs; [
        stdenv.cc
        binutils
        patch
        perl
        python3
        wget
        git
        unzip
        libxslt
        ncurses
        zlib
        openssl
        bc
        rsync
        file
        gnumake
        gawk
        which
        diffutils
        gettext
        openssh
        direnv
        buildScript
        cleanMountsScript
        unmountScript
        ncurses
        pkg-config
        quilt
        nix-ld
        ccache
        go
        fuse-overlayfs
        util-linux
        bindfs
      ];

      commonShellHook = ''
                  export NIX_LD="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
                  export NIX_LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib"
                  export TZ=UTC
                  export FLAKE_SOURCE="${self}"

                  # --- DYNAMIC FIX FOR NATIVE WRAPPER BYPASS ---
                  # OpenWrt's build system aggressively searches for <arch>-<os>-<libc>-<tool>.
                  # We dynamically grab the exact triplet Nix is using for the current builder
                  # and map those prefixed names back to our wrapped Nix tools.
                  TRIPLET="${pkgs.stdenv.hostPlatform.config}"
                  mkdir -p .nix-host-wrappers

                  for tool in gcc g++ cpp as ar ld nm ranlib strip objdump; do
                    if WRAPPED_TOOL=$(command -v "$tool"); then
                      ln -sf "$WRAPPED_TOOL" ".nix-host-wrappers/$TRIPLET-$tool"
                    fi
                  done

                  export PATH="$PWD/.nix-host-wrappers:$PATH"
                  # ---------------------------------------------

                  # Automatically remount if flake inputs have changed.
                  # Only unmounts FUSE mounts — build artifacts in .source-upper are preserved.
                  # Run 'clean-nss-mounts' manually if you want a full clean rebuild.
                  CURRENT_INPUTS_HASH="${openwrt-source.narHash}-${openwrt-packages.narHash}-${openwrt-luci.narHash}-${openwrt-routing.narHash}-${nss-packages.narHash}-${sqm-scripts-nss.narHash}-${luci-theme-argon.narHash}"
                  if [ -f .flake-inputs-hash ] && [ "$(cat .flake-inputs-hash)" != "$CURRENT_INPUTS_HASH" ]; then
                    echo "🔄 Flake inputs changed! Unmounting old mounts (build artifacts preserved)..."
                    unmount-nss-mounts
                  fi
                  echo "$CURRENT_INPUTS_HASH" > .flake-inputs-hash

                  # Setup COW for main source and feeds with bindfs permission mapping
                  if ! mountpoint -q source; then
                    echo "Mounting OpenWrt source and feeds using bindfs + fuse-overlayfs..."
                    mkdir -p .source-upper .source-work source .source-mapped

                    run_detached() {
                      bash -c '
                        for fd in $(ls /proc/self/fd); do
                          [ "$fd" -gt 2 ] && eval "exec $fd>&-" 2>/dev/null
                        done
                        exec "$@" < /dev/null >/dev/null 2>&1
                      ' bash "$@" &
                      disown
                    }

                    # Map OpenWrt source to be writable
                    if ! mountpoint -q .source-mapped; then
                      run_detached bindfs --no-allow-other -u $(id -u) -g $(id -g) -p u+rwX,g+rwX,o+rwX ${openwrt-source} .source-mapped
                    fi

                    # Create a merged lowerdir structure
                    mkdir -p .source-lower-staging/package
                    mkdir -p .source-lower-staging/feeds

                    mkdir -p .feeds-mapped/luci-theme-argon
                    mkdir -p .feeds-mapped/packages
                    mkdir -p .feeds-mapped/luci
                    mkdir -p .feeds-mapped/routing
                    mkdir -p .feeds-mapped/nss_packages
                    mkdir -p .feeds-mapped/sqm_scripts_nss
                    mkdir -p .feeds-merged .feeds-upper .feeds-work

                    map_feed() {
                      local src=$1
                      local mapped=$2
                      local upper=$3
                      local work=$4
                      local merged=$5
                      if ! mountpoint -q "$mapped"; then
                        run_detached bindfs --no-allow-other -u $(id -u) -g $(id -g) -p u+rwX,g+rwX,o+rwX "$src" "$mapped"
                      fi
                      mkdir -p "$upper" "$work" "$merged"
                      if ! mountpoint -q "$merged"; then
                        # Wait for bindfs to be ready
                        local retries=10
                        while [ $retries -gt 0 ] && ! mountpoint -q "$mapped"; do
                          sleep 0.2
                          retries=$((retries - 1))
                        done
                        run_detached fuse-overlayfs -o lowerdir="$mapped",upperdir="$upper",workdir="$work" "$merged"
                      fi
                    }

                    map_feed ${luci-theme-argon} .feeds-mapped/luci-theme-argon .feeds-upper/luci-theme-argon .feeds-work/luci-theme-argon .feeds-merged/luci-theme-argon
                    map_feed ${openwrt-packages} .feeds-mapped/packages .feeds-upper/packages .feeds-work/packages .feeds-merged/packages
                    map_feed ${openwrt-luci} .feeds-mapped/luci .feeds-upper/luci .feeds-work/luci .feeds-merged/luci
                    map_feed ${openwrt-routing} .feeds-mapped/routing .feeds-upper/routing .feeds-work/routing .feeds-merged/routing
                    map_feed ${nss-packages} .feeds-mapped/nss_packages .feeds-upper/nss_packages .feeds-work/nss_packages .feeds-merged/nss_packages
                    map_feed ${sqm-scripts-nss} .feeds-mapped/sqm_scripts_nss .feeds-upper/sqm_scripts_nss .feeds-work/sqm_scripts_nss .feeds-merged/sqm_scripts_nss

                    ln -sfn $PWD/.feeds-merged/luci-theme-argon .source-lower-staging/package/luci-theme-argon
                    ln -sfn $PWD/.feeds-merged/packages .source-lower-staging/feeds/packages
                    ln -sfn $PWD/.feeds-merged/luci .source-lower-staging/feeds/luci
                    ln -sfn $PWD/.feeds-merged/routing .source-lower-staging/feeds/routing
                    ln -sfn $PWD/.feeds-merged/nss_packages .source-lower-staging/feeds/nss_packages
                    ln -sfn $PWD/.feeds-merged/sqm_scripts_nss .source-lower-staging/feeds/sqm_scripts_nss

                    run_detached fuse-overlayfs -o lowerdir=.source-lower-staging:.source-mapped,upperdir=.source-upper,workdir=.source-work source

                    # Wait for mounts to be ready
                    sleep 1
                  fi

                  # Write a version file so scripts/getver.sh doesn't fall back to "unknown".
                  # getver.sh checks for a 'version' file first (try_version), before trying git.
                  # Without this, REVISION="unknown" and base-files gets version "700101.00001~unknown"
                  # which apk rejects as invalid. We derive the hash directly from the pinned flake
                  # input — no git required at runtime.
                  if [ ! -f source/version ]; then
                    echo "r0-${builtins.substring 0 7 (builtins.toString openwrt-source.rev)}" > source/version
                  fi

                  # Setup dl directory for caching (create unconditionally so cache action can save it)
                  mkdir -p "$PWD/dl"
                  if [ ! -L "$PWD/source/dl" ]; then
                    rm -rf "$PWD/source/dl"
                    ln -s "$PWD/dl" "$PWD/source/dl"
                  fi

                  # Setup ccache directory for caching (create unconditionally so cache action can save it)
                  mkdir -p "$PWD/.ccache"
                  if [ ! -L "$PWD/source/.ccache" ]; then
                    rm -rf "$PWD/source/.ccache"
                    ln -s "$PWD/.ccache" "$PWD/source/.ccache"
                  fi

                  # Apply custom patches
                  if [ -d "patches" ]; then
                    echo "Applying patches from local directory..."
                    PATCH_DIR="patches"
                  elif [ -d "$FLAKE_SOURCE/patches" ]; then
                    echo "Applying patches from flake source..."
                    PATCH_DIR="$FLAKE_SOURCE/patches"
                  else
                    PATCH_DIR=""
                  fi

                  if [ -n "$PATCH_DIR" ]; then
                    # For patches that modify the build system (Makefiles, Config.in, etc), apply them at root
                    for patch in "$PATCH_DIR"/*.patch; do
                      if [ -f "$patch" ]; then
                        if patch -d source -R -p1 -s -f --dry-run < "$patch" >/dev/null 2>&1; then
                          echo "✅ Patch $(basename $patch) already applied."
                        else
                          echo "🔧 Applying patch $(basename $patch)..."
                          if patch -d source -p1 < "$patch"; then
                            echo "✅ Applied $(basename $patch)"
                          else
                            echo "❌ Failed to apply $(basename $patch)"
                            if [ $CI == 1 ]; then exit 1; fi
                            echo "Continuing anyway so you can run cleanup scripts"
                          fi
                        fi
                      fi
                    done

                    # For package source patches (e.g. util-linux), copy them to destination
                    # This handles structure like patches/package/utils/util-linux/patches/100-...
                    if [ -d "$PATCH_DIR/package" ]; then
                      echo "Copying package patches..."
                      # Use rsync to merge directories. COW handles writability automatically.
                      rsync -a --no-perms "$PATCH_DIR/package/" source/package/
                    fi
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

                  # Generate new feeds.conf.default using src-link to our COW merged directories
                  cat > source/feeds.conf.default.new <<EOF
        src-link packages $PWD/.feeds-merged/packages
        src-link luci $PWD/.feeds-merged/luci
        src-link routing $PWD/.feeds-merged/routing
        src-link nss_packages $PWD/.feeds-merged/nss_packages
        src-link sqm_scripts_nss $PWD/.feeds-merged/sqm_scripts_nss
        EOF

                  # Check if feeds.conf.default changed
                  if [ -f source/feeds.conf.default ] && cmp -s source/feeds.conf.default source/feeds.conf.default.new; then
                    rm source/feeds.conf.default.new
                  else
                    mv source/feeds.conf.default.new source/feeds.conf.default
                    # Touch a marker file to indicate feeds need updating
                    touch source/.feeds_need_update
                  fi

                  echo "✅ NSS + APK Build Env Active"
                  echo "🚀 Run 'build-nss-image' to start."
      '';
    in {
      default = pkgs.mkShell {
        hardeningDisable = ["format"];
        buildInputs = commonBuildInputs;
        shellHook = commonShellHook;
      };
    });
  };
}
