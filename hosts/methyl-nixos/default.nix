_: let
  bootstrap = true; # set to false once flake is initialized (for caching)
  system = "x86_64-linux";
  username = "josh";
  isNixOS = true;

  myFeatures = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
    "hm-media"
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
  myNixOS = ./nixos.nix;
  myHome = ./home.nix;
in {
  inherit bootstrap system username isNixOS;

  features = myFeatures;
  modules = {
    home = [myHome];
    nixos = [myNixOS];
  };
}
