_: let
  bootstrap = true; # set to false once flake is initialized (for caching)
  system = "x86_64-linux";
  isNixOS = true;

  users.josh.isAdmin = true;

  features = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
    "hm-media"
    "hm-zed"
    "hm-nasmount"
    #
    "nixos-base"
    "nixos-audio"
    "nixos-network"
    "nixos-kde"
    "nixos-plymouth"
    "nixos-print"
    "nixos-gaming"
    "nixos-justnh"
    "nixos-udev"
    "nixos-flatpak"
    "nixos-podman"
    #
    "nixos-automounts"
    "nixos-zram"
    "nixos-oom"
    #
    "nixos-niri"
    #
    "nixos-lsfg"
    "nixos-korthos"
    "nixos-dmemcg"
  ];
}
