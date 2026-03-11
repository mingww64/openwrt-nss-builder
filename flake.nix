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
    luci-app-argon-config = {
      url = "github:jerrykuku/luci-app-argon-config";
      flake = false;
    };
    luci-app-wechatpush = {
      url = "github:tty228/luci-app-wechatpush";
      flake = false;
    };
    wrtbwmon = {
      url = "github:brvphoenix/wrtbwmon";
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
    luci-app-argon-config,
    luci-app-wechatpush,
    wrtbwmon,
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

    # Shared helper — checks for local modifications in upper layers that shadow/override upstream flake updates.
    makeShadowCheckScript = pkgs:
      pkgs.writeShellScriptBin "check-shadowed-source" ''
        export PATH="${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gnused}/bin:$PATH"
        echo "⚠️  Checking for shadowed source files (local modifications that override upstream updates)..."

        check_dir() {
          local upper="$1"
          local lower="$2"
          local label="$3"

          if [ -d "$upper" ]; then
            local shadowed=""
            while IFS= read -r f; do
              local rel_path="''${f#$upper/}"
              if [ -e "$lower/$rel_path" ]; then
                shadowed="$shadowed\n      - $rel_path"
              fi
            done < <(find "$upper" -type f -not -path "*/build_dir/*" -not -path "*/staging_dir/*" -not -path "*/bin/*" -not -path "*/tmp/*" -not -path "*/logs/*" -not -path "*/.git/*" -not -name "*.o" 2>/dev/null)

            if [ -n "$shadowed" ]; then
              echo "  - [$label] has local modifications shadowing upstream:"
              echo -e "$shadowed" | sed '/^$/d' | head -n 10
              local count=$(echo -e "$shadowed" | sed '/^$/d' | wc -l)
              if [ "$count" -gt 10 ]; then
                echo "      ...and $((count - 10)) more"
              fi
            fi
          fi
        }

        check_dir ".source-upper" "${openwrt-source}" "Main Source"
        check_dir ".feeds-upper/luci-theme-argon" "${luci-theme-argon}" "Feed: luci-theme-argon"
        check_dir ".feeds-upper/packages" "${openwrt-packages}" "Feed: packages"
        check_dir ".feeds-upper/luci" "${openwrt-luci}" "Feed: luci"
        check_dir ".feeds-upper/routing" "${openwrt-routing}" "Feed: routing"
        check_dir ".feeds-upper/nss_packages" "${nss-packages}" "Feed: nss_packages"
        check_dir ".feeds-upper/sqm_scripts_nss" "${sqm-scripts-nss}" "Feed: sqm_scripts_nss"
        check_dir ".feeds-upper/luci-app-argon-config" "${luci-app-argon-config}" "Feed: luci-app-argon-config"
        check_dir ".feeds-upper/luci-app-wechatpush" "${luci-app-wechatpush}" "Feed: luci-app-wechatpush"
        check_dir ".feeds-upper/wrtbwmon" "${wrtbwmon}" "Feed: wrtbwmon"

        echo "-------------------------------------------------------------------------------"
      '';
  in {
    apps = forAllSystems (system: let
      pkgs = nixpkgsFor.${system};
      cleanMountsScript = makeCleanMountsScript pkgs;
      unmountScript = makeUnmountScript pkgs;
      shadowCheckScript = makeShadowCheckScript pkgs;
    in {
      clean-nss-mounts = {
        type = "app";
        program = "${cleanMountsScript}/bin/clean-nss-mounts";
      };
      unmount-nss-mounts = {
        type = "app";
        program = "${unmountScript}/bin/unmount-nss-mounts";
      };
      check-shadowed-source = {
        type = "app";
        program = "${shadowCheckScript}/bin/check-shadowed-source";
      };
    });

    devShells = forAllSystems (system: let
      pkgs = nixpkgsFor.${system};

      routerIp = "192.168.15.1";
      routerUser = "root";

      cleanMountsScript = makeCleanMountsScript pkgs;
      unmountScript = makeUnmountScript pkgs;
      shadowCheckScript = makeShadowCheckScript pkgs;

      buildScript = pkgs.writeShellScriptBin "build-nss-image" ''
        set -e
        set -o pipefail

        PROFILE="linksys_mr7350"
        SYNC_PACKAGES=0
        MAKE_ONLY=0
        MENUCONFIG=0
        BUILD_IB=0
        BUILD_SDK=0
        PRESERVE_CONFIG=0
        EXTRA_MAKE_ARGS="V=s"

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
            --imagebuilder)
              BUILD_IB=1
              shift
              ;;
            --sdk)
              BUILD_SDK=1
              shift
              ;;
            --preserve-config)
              PRESERVE_CONFIG=1
              shift
              ;;
            --make-args)
              EXTRA_MAKE_ARGS="$2"
              shift 2
              ;;
            *)
              echo "Unknown option: $1"
              exit 1
              ;;
          esac
        done

        if [ "$EXTRA_MAKE_ARGS" = "none" ]; then
          EXTRA_MAKE_ARGS=""
        fi

        EXTRA_PACKAGES=""
        if [ -f ./packages.txt ]; then
          EXTRA_PACKAGES=$(cat ./packages.txt)
        elif [ -f "$FLAKE_SOURCE/packages.txt" ]; then
          EXTRA_PACKAGES=$(cat "$FLAKE_SOURCE/packages.txt")
        fi

        EXTRA_CONFIG=""
        if [ -f ./config.txt ]; then
          EXTRA_CONFIG="$PWD/config.txt"
        elif [ -f "$FLAKE_SOURCE/config.txt" ]; then
          EXTRA_CONFIG="$FLAKE_SOURCE/config.txt"
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
           make -j$(nproc) $EXTRA_MAKE_ARGS 2>&1 | tee -a "$LOGFILE" || {
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


          rm -f .feeds_need_update
        else
          echo "--- Feeds are up to date, skipping install ---" | tee -a "$LOGFILE"
        fi

        # Determine seed file path (needed for profile search regardless of PRESERVE_CONFIG)
        SEED_FILE="nss-setup/config-nss.seed"
        if [ ! -f "$SEED_FILE" ] && [ -f "$FLAKE_SOURCE/nss-setup/config-nss.seed" ]; then
          SEED_FILE="$FLAKE_SOURCE/nss-setup/config-nss.seed"
        fi

        if [ "$PRESERVE_CONFIG" -eq 1 ] && [ -f .config ]; then
          echo "--- Preserving existing .config ---" | tee -a "$LOGFILE"
        else
          # Always start from the seed so .config is in a clean, known state
          cp "$SEED_FILE" .config

          # Disable all sub-targets and devices — the correct ones are re-enabled below
          sed -i 's/^CONFIG_TARGET_qualcommax_\([a-z0-9]*\)=y/# CONFIG_TARGET_qualcommax_\1 is not set/' .config
          sed -i 's/^CONFIG_TARGET_qualcommax_[a-z0-9]*_DEVICE_[a-zA-Z0-9_-]*=y/# & is not set/' .config
        fi

        # Fuzzy search for the profile in the seed (always uses seed as source of truth)
        MATCHED_PROFILES=$(grep -io "CONFIG_TARGET_qualcommax_[a-z0-9]*_DEVICE_.*$PROFILE.*" "$SEED_FILE" 2>/dev/null | sed 's/ is not set//;s/=y//;s/^# //' | sort -u || true)

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

        DEVICE_NAME=$(echo "$MATCHED_PROFILE" | sed -E 's/CONFIG_TARGET_qualcommax_[a-z0-9]+_DEVICE_(.*)/\1/')

        # Fuzzy search for device-specific package files
        DEVICE_PKG_FILES=$(find .. "$FLAKE_SOURCE" -maxdepth 1 -type f -iname "*package*$DEVICE_NAME*.txt" ! -name "packages.txt" -exec readlink -f {} + 2>/dev/null | sort -u || true)
        if [ -z "$DEVICE_PKG_FILES" ]; then
          DEVICE_PKG_FILES=$(find .. "$FLAKE_SOURCE" -maxdepth 1 -type f -iname "*package*$PROFILE*.txt" ! -name "packages.txt" -exec readlink -f {} + 2>/dev/null | sort -u || true)
        fi

        if [ -n "$DEVICE_PKG_FILES" ]; then
          for f in $DEVICE_PKG_FILES; do
            echo "--- Appending device package file: $(basename "$f") ---" | tee -a "$LOGFILE"
            EXTRA_PACKAGES="$EXTRA_PACKAGES $(cat "$f")"
          done
        fi

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

        if [ "$BUILD_IB" -eq 1 ]; then
          echo "--- Enabling ImageBuilder build ---"
          echo "CONFIG_IB=y" >> .config
        fi

        if [ "$BUILD_SDK" -eq 1 ]; then
          echo "--- Enabling SDK build ---"
          echo "CONFIG_SDK=y" >> .config
        fi

        if [ -n "$EXTRA_CONFIG" ]; then
          echo "--- Appending extra config from $(basename "$EXTRA_CONFIG") ---" | tee -a "$LOGFILE"
          cat "$EXTRA_CONFIG" >> .config
        fi

        # Fuzzy search for device-specific config files (avoid matching global config.txt)
        DEVICE_CONF_FILES=$(find .. "$FLAKE_SOURCE" -maxdepth 1 -type f -iname "*config*$DEVICE_NAME*.txt" ! -name "config.txt" -exec readlink -f {} + 2>/dev/null | sort -u || true)
        if [ -z "$DEVICE_CONF_FILES" ]; then
          DEVICE_CONF_FILES=$(find .. "$FLAKE_SOURCE" -maxdepth 1 -type f -iname "*config*$PROFILE*.txt" ! -name "config.txt" -exec readlink -f {} + 2>/dev/null | sort -u || true)
        fi

        if [ -n "$DEVICE_CONF_FILES" ]; then
          for f in $DEVICE_CONF_FILES; do
            echo "--- Appending device config from $(basename "$f") ---" | tee -a "$LOGFILE"
            cat "$f" >> .config
          done
        fi

        make defconfig $EXTRA_MAKE_ARGS 2>&1 | tee -a "$LOGFILE"

        echo "--- Downloading sources ---" | tee -a "$LOGFILE"
        make download -j$(nproc) $EXTRA_MAKE_ARGS 2>&1 | tee -a "$LOGFILE"

        echo "--- Starting image build ---" | tee -a "$LOGFILE"
        make -j$(nproc) $EXTRA_MAKE_ARGS 2>&1 | tee -a "$LOGFILE" || {
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
        shadowCheckScript
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
                  export FLAKE_SOURCE="${self}"

                  # --- DYNAMIC FIX FOR NATIVE WRAPPER BYPASS ---
                  # OpenWrt's build system aggressively searches for <arch>-<os>-<libc>-<tool>.
                  # We dynamically grab the exact triplet Nix is using for the current builder
                  # and map those prefixed names back to our wrapped Nix tools.
                  TRIPLET="${pkgs.stdenv.hostPlatform.config}"
                  mkdir -p .nix-host-wrappers

                  for tool in gcc g++ cpp as ar ld nm ranlib strip objdump; do
                    if [ -x "$(command -v $tool)" ]; then
                      ln -sf "$(command -v $tool)" ".nix-host-wrappers/$TRIPLET-$tool"
                    fi
                  done

                  # Ensure native setuid FUSE wrappers are preferred over nixpkgs ones
                  for f in fusermount fusermount3; do
                    if [ -e "/run/wrappers/bin/$f" ]; then
                      ln -sf "/run/wrappers/bin/$f" ".nix-host-wrappers/$f"
                    elif [ -x "$(command -v $f 2>/dev/null)" ]; then
                      ln -sf "$(command -v $f)" ".nix-host-wrappers/$f"
                    elif [ -e "/usr/bin/$f" ]; then
                      ln -sf "/usr/bin/$f" ".nix-host-wrappers/$f"
                    elif [ -e "/bin/$f" ]; then
                      ln -sf "/bin/$f" ".nix-host-wrappers/$f"
                    fi
                  done

                  export PATH="$PWD/.nix-host-wrappers:$PATH"
                  # ---------------------------------------------

                  # Pre-populate staging_dir/host with Nix tools so OpenWrt skips rebuilding them.
                  # OpenWrt checks for stamp files in staging_dir/host/stamp/ to determine
                  # whether a tool needs to be compiled. By symlinking Nix binaries and
                  # touching the stamps, we skip heavy compile steps for cmake, ninja, etc.
                  STAGING_HOST="source/staging_dir/host"
                  if [ -d source ]; then
                    mkdir -p "$STAGING_HOST/bin" "$STAGING_HOST/stamp"

                    # Helper: symlink a Nix binary into staging_dir/host/bin and touch its stamp
                    seed_host_tool() {
                      local stamp_name="$1"; shift
                      for tool in "$@"; do
                        local bin
                        bin="$(command -v "$tool" 2>/dev/null || true)"
                        if [ -n "$bin" ]; then
                          ln -sf "$bin" "$STAGING_HOST/bin/$tool" 2>/dev/null || true
                        fi
                      done
                      touch "$STAGING_HOST/stamp/.$stamp_name"_installed 2>/dev/null || true
                    }

                    seed_host_tool ninja    ninja
                    seed_host_tool m4       m4
                    seed_host_tool xz       xz xzcat unxz lzma
                    seed_host_tool zstd     zstd zstdcat unzstd zstdmt

                    echo "✅ Staged Nix host tools into $STAGING_HOST"
                  fi

                  if [ -d "patches" ]; then
                    PATCH_DIR="patches"
                  elif [ -d "${self}/patches" ]; then
                    PATCH_DIR="${self}/patches"
                  else
                    PATCH_DIR=""
                  fi

                  # Automatically remount if flake inputs have changed.
                  # Only unmounts FUSE mounts — build artifacts in .source-upper are preserved.
                  # Run 'clean-nss-mounts' manually if you want a full clean rebuild.
                  CURRENT_INPUTS_HASH="${openwrt-source.narHash}-${openwrt-packages.narHash}-${openwrt-luci.narHash}-${openwrt-routing.narHash}-${nss-packages.narHash}-${sqm-scripts-nss.narHash}-${luci-theme-argon.narHash}-${luci-app-argon-config.narHash}-${luci-app-wechatpush.narHash}-${wrtbwmon.narHash}"
                  INPUTS_CHANGED=0
                  if [ -f .flake-inputs-hash ] && [ "$(cat .flake-inputs-hash)" != "$CURRENT_INPUTS_HASH" ]; then
                    echo "🔄 Flake inputs changed! Unmounting old mounts (build artifacts preserved)..."
                    unmount-nss-mounts
                    INPUTS_CHANGED=1
                  fi

                  # Only clean upper-layer patch artifacts when source is NOT yet mounted.
                  # Modifying .source-upper/ while the FUSE overlay is live causes cache
                  # desync — the overlay keeps serving stale inodes, making patch reads fail.
                  if ! mountpoint -q source && [ -n "$PATCH_DIR" ]; then
                    for patch in "$PATCH_DIR"/*.patch; do
                      [ -f "$patch" ] || continue
                      awk '/^\+\+\+ / {sub(/^[ab]\//, "", $2); print $2}' "$patch" | while read -r pf; do
                        if [ -n "$pf" ]; then
                          if [[ "$pf" == feeds/* ]]; then
                            feed_name=$(echo "$pf" | cut -d/ -f2)
                            feed_rel_path=$(echo "$pf" | cut -d/ -f3-)
                            if [ -e ".feeds-upper/$feed_name/$feed_rel_path" ]; then
                              rm -f ".feeds-upper/$feed_name/$feed_rel_path"
                            fi
                          elif [ -e ".source-upper/$pf" ]; then
                            rm -f ".source-upper/$pf"
                          fi
                        fi
                      done
                    done
                  fi

                  # Report shadowed files only after patches have been cleaned (to reduce noise)
                  if [ "$INPUTS_CHANGED" = "1" ]; then
                    check-shadowed-source
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
                      run_detached bindfs --no-allow-other -u $(id -u) -g $(id -g) -p a-w,u+w ${openwrt-source} .source-mapped
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
                    mkdir -p .feeds-mapped/luci-app-argon-config
                    mkdir -p .feeds-mapped/luci-app-wechatpush
                    mkdir -p .feeds-mapped/wrtbwmon
                    mkdir -p .feeds-merged .feeds-upper .feeds-work

                    map_feed() {
                      local src=$1
                      local mapped=$2
                      local upper=$3
                      local work=$4
                      local merged=$5
                      if ! mountpoint -q "$mapped"; then
                        run_detached bindfs --no-allow-other -u $(id -u) -g $(id -g) -p a-w,u+w "$src" "$mapped"
                        # Wait for bindfs to be ready
                        local retries=10
                        while [ $retries -gt 0 ] && ! mountpoint -q "$mapped"; do
                          sleep 0.2
                          retries=$((retries - 1))
                        done
                      fi
                      mkdir -p "$upper" "$work" "$merged"
                      # Mount the local checkout over the standard tree
                      if ! mountpoint -q "$merged"; then
                        run_detached fuse-overlayfs -o lowerdir="$mapped",upperdir="$upper",workdir="$work" "$merged"
                        # Wait for merge mount
                        local retries=10
                        while [ $retries -gt 0 ] && ! mountpoint -q "$merged"; do
                          sleep 0.2
                          retries=$((retries - 1))
                        done
                      fi
                    }

                    map_feed ${luci-theme-argon} .feeds-mapped/luci-theme-argon .feeds-upper/luci-theme-argon .feeds-work/luci-theme-argon .feeds-merged/luci-theme-argon
                    map_feed ${openwrt-packages} .feeds-mapped/packages .feeds-upper/packages .feeds-work/packages .feeds-merged/packages
                    map_feed ${openwrt-luci} .feeds-mapped/luci .feeds-upper/luci .feeds-work/luci .feeds-merged/luci
                    map_feed ${openwrt-routing} .feeds-mapped/routing .feeds-upper/routing .feeds-work/routing .feeds-merged/routing
                    map_feed ${nss-packages} .feeds-mapped/nss_packages .feeds-upper/nss_packages .feeds-work/nss_packages .feeds-merged/nss_packages
                    map_feed ${sqm-scripts-nss} .feeds-mapped/sqm_scripts_nss .feeds-upper/sqm_scripts_nss .feeds-work/sqm_scripts_nss .feeds-merged/sqm_scripts_nss
                    map_feed ${luci-app-argon-config} .feeds-mapped/luci-app-argon-config .feeds-upper/luci-app-argon-config .feeds-work/luci-app-argon-config .feeds-merged/luci-app-argon-config
                    map_feed ${luci-app-wechatpush} .feeds-mapped/luci-app-wechatpush .feeds-upper/luci-app-wechatpush .feeds-work/luci-app-wechatpush .feeds-merged/luci-app-wechatpush
                    map_feed ${wrtbwmon} .feeds-mapped/wrtbwmon .feeds-upper/wrtbwmon .feeds-work/wrtbwmon .feeds-merged/wrtbwmon

                    ln -sfn $PWD/.feeds-merged/luci-theme-argon .source-lower-staging/package/luci-theme-argon
                    ln -sfn $PWD/.feeds-merged/packages .source-lower-staging/feeds/packages
                    ln -sfn $PWD/.feeds-merged/luci .source-lower-staging/feeds/luci
                    ln -sfn $PWD/.feeds-merged/routing .source-lower-staging/feeds/routing
                    ln -sfn $PWD/.feeds-merged/nss_packages .source-lower-staging/feeds/nss_packages
                    ln -sfn $PWD/.feeds-merged/sqm_scripts_nss .source-lower-staging/feeds/sqm_scripts_nss
                    ln -sfn $PWD/.feeds-merged/luci-app-argon-config .source-lower-staging/package/luci-app-argon-config
                    ln -sfn $PWD/.feeds-merged/luci-app-wechatpush .source-lower-staging/package/luci-app-wechatpush
                    ln -sfn $PWD/.feeds-merged/wrtbwmon .source-lower-staging/package/wrtbwmon

                    # Final read-write source merge
                    run_detached fuse-overlayfs -o lowerdir=.source-lower-staging:.source-mapped,upperdir=.source-upper,workdir=.source-work source

                    # Wait for all background mount jobs to complete
                    sleep 1
                  fi

                  # Write a version file so scripts/getver.sh doesn't fall back to "unknown".
                  # getver.sh checks for a 'version' file first (try_version), before trying git.
                  # Without this, REVISION="unknown" and base-files gets version "700101.00001~unknown"
                  # which apk rejects as invalid. We derive the hash directly from the pinned flake
                  # input — no git required at runtime.
                  if [ ! -f source/version ]; then
                    echo "r0-${builtins.substring 0 7 (toString openwrt-source.rev)}" > source/version
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

                  # Apply custom patches uniformly
                  if [ -d "patches" ]; then
                    PATCH_DIR="patches"
                  elif [ -d "$FLAKE_SOURCE/patches" ]; then
                    PATCH_DIR="$FLAKE_SOURCE/patches"
                  else
                    PATCH_DIR=""
                  fi

                  if [ -n "$PATCH_DIR" ]; then
                    echo "--- Applying Unified Patches ---"
                    # For patches that modify the build system (Makefiles, Config.in, etc), apply them at root
                    for patch in "$PATCH_DIR"/*.patch; do
                      if [ -f "$patch" ]; then
                        echo "🔧 Applying patch $(basename $patch)..."

                        # Determine if patch targets a feed
                        ft=$(awk '/^\+\+\+ / {sub(/^[ab]\//, "", $2); print $2}' "$patch" | grep -m1 '^feeds/' | cut -d/ -f2 || true)

                        if [ -n "$ft" ]; then
                          # Apply directly into the resolved feed mount path to bypass symlink limits
                          _stripped_patch=$(cat "$patch" | sed "s|a/feeds/$ft/|a/|g; s|b/feeds/$ft/|b/|g")
                          if echo "$_stripped_patch" | patch -d ".feeds-merged/$ft" -p1 --forward > /dev/null 2>&1; then
                            echo "  ✅ Applied (Feed: $ft)"
                          else
                            if echo "$_stripped_patch" | patch -d ".feeds-merged/$ft" -p1 --dry-run --reverse --force > /dev/null 2>&1; then
                              echo "  -- Already applied (Feed: $ft)"
                            else
                              echo "  ❌ Failed to apply (Feed: $ft)"
                              if [ "${CI:-0}" = "1" ]; then exit 1; fi
                            fi
                          fi
                        else
                          if patch -d source -p1 --forward < "$patch" > /dev/null 2>&1; then
                            echo "  ✅ Applied"
                          else
                            if patch -d source -p1 --dry-run --reverse --force < "$patch" > /dev/null 2>&1; then
                              echo "  -- Already applied"
                            else
                              echo "  ❌ Failed to apply"
                              if [ "${CI:-0}" = "1" ]; then exit 1; fi
                            fi
                          fi
                        fi
                      fi
                    done

                    # For package source patches (e.g. util-linux), copy them to destination
                    # This handles structure like patches/package/utils/util-linux/patches/100-...
                    if [ -d "$PATCH_DIR/package" ]; then
                      echo "Copying package patches..."
                      rsync -a --no-perms "$PATCH_DIR/package/" source/package/
                    fi
                  fi

                  # Sync custom rootfs files overlay into OpenWrt source
                  if [ -d "files" ]; then
                    echo "Copying custom rootfs files from local directory..."
                    rsync -a --no-perms "files/" source/files/
                  elif [ -d "${self}/files" ]; then
                    echo "Copying custom rootfs files from flake source..."
                    rsync -a --no-perms "${self}/files/" source/files/
                  fi

                  if [ "$CI" = "1" ]; then
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
