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
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      routerIp = "192.168.15.1";
      routerUser = "root";

      buildScript = pkgs.writeShellScriptBin "build-nss-image" ''
        set -e
        PACKAGES=""
        if [ "$1" == "--sync-packages" ]; then
          LOGFILE="../build-$(date +%Y%m%d-%H%M%S)-sync.log"
          echo "--- Syncing package list from router using apk ---" | tee -a "$LOGFILE"

          # Merge static package list and ssh apk info, remove duplicates
          STATIC_PACKAGES="acme acme-acmesh acme-common apk-mbedtls avahi-nodbus-daemon busybox ca-bundle certtool cgi-io collectd collectd-mod-cpu collectd-mod-interface collectd-mod-iwinfo collectd-mod-load collectd-mod-memory collectd-mod-network collectd-mod-rrdtool curl dawn dbus ddns-scripts ddns-scripts-cloudflare ddns-scripts-services dnsmasq dropbear e2fsprogs etherwake firewall4 fstools fwtool getrandom hostapd-common ip-tiny iperf3 ipq-wifi-linksys_mr7350 iw jansson4 jshn jsonfilter libatomic1 libavahi-nodbus-support libblkid1 libblobmsg-json20251208 libdaemon libdbus libe2p2 libev libexpat libext2fs2 libgcrypt libgmp10 libgnutls libgpg-error libiperf3 libiwinfo-data libiwinfo20230701 libjson-c5 libjson-script20251208 libltdl7 liblua5.1.5 liblucihttp-lua liblucihttp-ucode liblucihttp0 libmbedtls21 libmnl0 libncurses6 libnettle8 libnftnl11 libnghttp2-14 libnl-tiny1 libopenssl-conf libopenssl3 libpcap1 libpcre2 libprotobuf-c libpthread libreadline8 librrd1 librt libsmartcols1 libss2 libstdcpp6 libubox20251208 libubus-lua libubus20251202 libuci20250120 libuclient20201210 libucode20230711 libudebug libustream-mbedtls20201210 libuuid1 libuv1 libwebsockets-full libxml2-16 logd losetup lua luci luci-app-acme luci-app-dawn luci-app-ddns luci-app-filemanager luci-app-firewall luci-app-ocserv luci-app-package-manager luci-app-statistics luci-app-tailscale-community luci-app-ttyd luci-app-upnp luci-app-wol luci-base luci-lib-base luci-lib-ip luci-lib-jsonc luci-lib-nixio luci-lib-uqr luci-light luci-lua-runtime luci-mod-admin-full luci-mod-network luci-mod-status luci-mod-system luci-nginx luci-proto-ipv6 luci-proto-ppp luci-theme-argon luci-theme-bootstrap mdns-repeater miniupnpd-nftables mtd netifd nftables-json nginx-mod-luci nginx-mod-ubus nginx-ssl nginx-ssl-util ocserv odhcp6c odhcpd-ipv6only openssl-util openwrt-keyring ppp ppp-mod-pppoe procd procd-seccomp procd-ujail resolveip rpcd rpcd-mod-file rpcd-mod-iwinfo rpcd-mod-luci rpcd-mod-rrdns rpcd-mod-ucode rrdtool1 socat tailscale tcpdump terminfo ttyd ubi-utils uboot-envtools ubox ubus ubusd uci uclient-fetch ucode ucode-mod-digest ucode-mod-fs ucode-mod-html ucode-mod-log ucode-mod-lua ucode-mod-math ucode-mod-nl80211 ucode-mod-rtnl ucode-mod-ubus ucode-mod-uci ucode-mod-uloop udp-broadcast-relay-redux uhttpd uhttpd-mod-ubus umdns urandom-seed urngd usign uwsgi uwsgi-cgi-plugin uwsgi-luci-support uwsgi-syslog-plugin wget-ssl wifi-scripts wireless-regdb wpad-mbedtls zlib"
          SSH_PACKAGES=$(ssh ${routerUser}@${routerIp} "apk info" | grep -vE '(kmod|kernel|base-files|libc|libgcc|qca-nss|nss-dp|ath11k)')
          PACKAGES=$(echo "$STATIC_PACKAGES $SSH_PACKAGES" | tr ' ' '\n' | sort -u | tr '\n' ' ')
          echo -e "--- Including packages: --- \n $PACKAGES \n--- End of package list ---" | tee -a "$LOGFILE"
        fi
        
        LOGFILE="../build-$(date +%Y%m%d-%H%M%S).log"
        # Generate config fragment to enable all packages
        cd source
        CONFIG_FRAGMENT=""
        if [ -n "$PACKAGES" ]; then
          for pkg in $PACKAGES; do
            # Only use valid OpenWrt package names
            if [[ $pkg =~ ^[a-zA-Z0-9._+-]+$ ]]; then
              echo "CONFIG_PACKAGE_$pkg=y" >> .config.fragment
            fi
          done
          # Append config fragment to .config before defconfig
          if [ ! -f .config ]; then
            cp nss-setup/config-nss.seed .config
          fi
          cat .config.fragment >> .config
          rm -f .config.fragment
          make defconfig V=s 2>&1 | tee -a "$LOGFILE"
        fi


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

        # Build the image using the config seed
        [ ! -f .config ] && cp nss-setup/config-nss.seed .config && make defconfig V=s 2>&1 | tee -a "$LOGFILE"

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
        ncurses pkg-config quilt nix-ld
      ];

      commonShellHook = ''
          export NIX_LD="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
          export NIX_LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib"

          if [ ! -d "source" ]; then
            echo "Cloning OpenWrt source..."
            git clone -b main-nss https://github.com/qosmio/openwrt-ipq.git source
          fi
          # Prepare writable copies of feeds (separate from ./feeds symlink dir)
          mkdir -p source/feeds-src
          if [ ! -d "source/feeds-src/packages" ]; then
            cp -r ${openwrt-packages} source/feeds-src/packages
            chmod -R u+w source/feeds-src/packages
          fi
          if [ ! -d "source/feeds-src/luci" ]; then
            cp -r ${openwrt-luci} source/feeds-src/luci
            chmod -R u+w source/feeds-src/luci
          fi
          if [ ! -d "source/feeds-src/routing" ]; then
            cp -r ${openwrt-routing} source/feeds-src/routing
            chmod -R u+w source/feeds-src/routing
          fi
          if [ ! -d "source/feeds-src/nss_packages" ]; then
            cp -r ${nss-packages} source/feeds-src/nss_packages
            chmod -R u+w source/feeds-src/nss_packages
          fi
          if [ ! -d "source/feeds-src/sqm_scripts_nss" ]; then
            cp -r ${sqm-scripts-nss} source/feeds-src/sqm_scripts_nss
            chmod -R u+w source/feeds-src/sqm_scripts_nss
          fi
          if [ ! -d "source/package/luci-theme-argon" ]; then
            cp -r ${luci-theme-argon} source/package/luci-theme-argon
            chmod -R u+w source/package/luci-theme-argon
          fi
          cat > source/feeds.conf.default <<EOF
src-link packages ../feeds-src/packages
src-link luci ../feeds-src/luci
src-link routing ../feeds-src/routing
src-link nss_packages ../feeds-src/nss_packages
src-link sqm_scripts_nss ../feeds-src/sqm_scripts_nss
EOF

          # Automate device selection for MR7350 in config-nss.seed
          sed -i 's/^# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_linksys_mr7350 is not set$/CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_linksys_mr7350=y/' source/nss-setup/config-nss.seed
          sed -i 's/^# CONFIG_TARGET_qualcommax_ipq60xx is not set$/CONFIG_TARGET_qualcommax_ipq60xx=y/' source/nss-setup/config-nss.seed

          sed -i 's/^CONFIG_TARGET_qualcommax_ipq807x=.$/# CONFIG_TARGET_qualcommax_ipq807x is not set/' source/nss-setup/config-nss.seed

          echo "✅ NSS + APK Build Env Active"
          echo "🚀 Run 'build-nss-image' to start."
        '';

    in {
      devShells.${system} = {
        default = pkgs.mkShell {
          hardeningDisable = [ "format" ];
          buildInputs = commonBuildInputs;
          shellHook = commonShellHook;
        };
      };
    };
}

