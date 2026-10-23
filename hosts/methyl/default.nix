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
    #"nixos-kde"
    "nixos-gnome"
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
}
