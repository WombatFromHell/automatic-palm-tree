_: {
  system = "x86_64-linux";
  isNixOS = true;
  isQemuVM = false;

  users.josh.isAdmin = true;

  features = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
    "hm-media"
    "hm-nasmount"
    "hm-syncthing"
    "hm-xilo"
    "hm-herdr"
    #
    "hm-zed"
    "hm-brave"
    #
    "hm-tmux"
    "hm-njust"
    #
    "nixos-base"
    "nixos-audio"
    "nixos-network"
    "nixos-kde"
    #"nixos-gnome"
    "nixos-plymouth"
    "nixos-print"
    "nixos-gaming"
    "nixos-scx"
    "nixos-udev"
    "nixos-flatpak"
    "nixos-podman"
    #
    # "nixos-cachyos"
    "nixos-lix"
    #
    "nixos-automounts"
    # "nixos-zram"
    "nixos-zswap"
    "nixos-oom"
    #
    "nixos-niri"
    "nixos-dms"
    #
    "nixos-lsfg"
    "nixos-korthos"
    "nixos-dmemcg"
  ];

  # Stage 1 for bootstrap.sh (see lib/stages.nix): boot-critical features only. Home Manager
  # users are dropped by the stage narrowing, so the light config carries no desktop/HM
  # closure and the machine gets swap before it builds the full system.
  # `nixos-oom` is here because base.nix sets `features.oomd.notify`; the option must exist in
  # stage 1 or the light config fails to evaluate. lib/stages.nix disables the service itself.
  bootFeatures = [
    "nixos-base"
    "nixos-zswap"
    "nixos-oom"
  ];
}
