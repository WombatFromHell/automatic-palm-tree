_: let
  base = import ../methyl/default.nix {};
in
  base
  // {
    # T2 laptop POC: KaiT2en + the baseline stack, no desktop (methyl's niri/dms/gaming/print).
    # bootstrap is inherited as true from ../methyl/default.nix: the first switch boots the
    # stock kernel and writes /etc/nix/nix.conf (incl. the KaiT2en cache).
    # ponytail: flip bootstrap = false on the laptop so the next switch substitutes the patched
    # kernel + modules from https://nix.channings.me instead of compiling them.
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
