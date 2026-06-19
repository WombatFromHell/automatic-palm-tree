_: {
  bootstrap = true; # set to false once flake is initialized (for caching)
  system = "x86_64-linux";
  isNixOS = true;
  isQemuVM = false;

  users.josh.isAdmin = true;

  features = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
    "hm-media"
    "hm-zed"
    "hm-nasmount"
    "hm-syncthing"
    #
    "nixos-base"
    "nixos-audio"
    "nixos-network"
    "nixos-kde"
    "nixos-plymouth"
    "nixos-print"
    "nixos-gaming"
    "nixos-scx"
    "nixos-justnh"
    "nixos-udev"
    "nixos-flatpak"
    "nixos-podman"
    #
    "nixos-cachyos"
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
}
