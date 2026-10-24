_: let
  base = import ../methyl-base/manifest.nix {};
in
  base
  // {
    # T2 laptop POC: KaiT2en + the baseline stack, no desktop (methyl's niri/dms/gaming/print).
    # Cache gating lives in modules/caches.nix: listing "nixos-kait2en" requires the kait2en
    # cache, the switch that writes /etc/nix/nix.conf builds locally (fallback), the next one
    # substitutes the patched kernel, modules and brcm firmware from https://nix.channings.me.
    features = [
      "hm-base"
      "hm-dev"
      "nixos-base"
      "nixos-audio"
      "nixos-network"
      "nixos-kait2en"
      "nixos-zswap"
      "nixos-oom"
    ];
  }
