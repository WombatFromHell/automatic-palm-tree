# The cache registry — the only place a cache url/key is written.
#
# `substituters`/`trustedPublicKeys` are the values for `nix --option extra-substituters …`, so
# bootstrap.sh can hand the same caches to a build on a host whose nix.conf does not carry them
# yet: without them, the first switch builds cache-fed paths locally (a kernel compile and a
# firmware VM on a RAM-constrained laptop). argv beats env here - `--option` survives sudo's
# env_reset and applies whether or not the invoking user is a trusted user. Eval only, no builds.
let
  registry = {
    cachyosKernels = {
      url = "https://cache.lantian.pub/lantian";
      publicKey = "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ=";
      note = "xddxdd's CachyOS kernel for Nix";
    };
    kait2en = {
      url = "https://nix.channings.me";
      publicKey = "garage:JZet/fsItH8cJ6SKLci1+BuMIQGDfZSa/8GxGpKcxss=";
      note = "KaiT2en's CI-built T2 kernel, out-of-tree modules and brcm blobs (rev 02c087f3).";
    };
    nix-community = {
      url = "https://nix-community.cachix.org/";
      publicKey = "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";
      note = "nix-community builds (CachyOS kernels among them).";
    };
    xilopkgs = {
      url = "https://xilo.nanogoblin.duckdns.org/c/default/xilopkgs";
      publicKey = "xilopkgs:t7bPM4c3zgmTCtV7XYCDTGiShoplykV8ZhQnEbukaFU=";
      note = "Chilled nixpkgs rebuilt through our overlay.";
    };
    wombatfromhell = {
      url = "https://wombatfromhell.cachix.org";
      publicKey = "wombatfromhell.cachix.org-1:pyIVJJkoLxkjH/MKK1ylrrdJKPpm+aXLeD2zAqVk9lA=";
      note = "build cache for niri-spicy";
    };
  };
in {
  inherit registry;
  substituters =
    builtins.concatStringsSep " " (map (n: registry.${n}.url) (builtins.attrNames registry));
  trustedPublicKeys =
    builtins.concatStringsSep " " (map (n: registry.${n}.publicKey) (builtins.attrNames registry));
}
