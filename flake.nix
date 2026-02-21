{
  description = "OpenWrt NSS Build Environment (wrapper)";

  inputs.nss-env.url = "path:./nix";

  outputs = { nss-env, ... }:
    nss-env.outputs;
}