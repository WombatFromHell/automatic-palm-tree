_: {
  features = [
    "hm-base"
    "hm-gpg"
    "hm-tmux"
    "hm-creds"
    "hm-njust"
    #
    "nixos-base"
    "nixos-audio"
    "nixos-network"
    "nixos-plymouth"
    "nixos-print"
    #
    "nixos-automounts"
    # One tier per host: nixos-swap ships both, and the zram tier needs
    # features.zswap.enable = false beside it (ADR-56394370887f).
    "nixos-swap"
    "nixos-oom"
  ];
}
