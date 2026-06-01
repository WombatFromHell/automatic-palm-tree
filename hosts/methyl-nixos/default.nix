_: let
  bootstrap = true; # set to false once flake is initialized (for caching)
  system = "x86_64-linux";
  username = "josh";
  isNixOS = true;

  myNixOS = ./nixos.nix;
  myHome = ./home.nix;
in {
  inherit bootstrap system username isNixOS;

  features = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
    "hm-media"
    #
    "nixos-base"
    "nixos-audio"
    "nixos-network"
    "nixos-kde"
    "nixos-print"
    "nixos-gaming"
    "nixos-justnh"
  ];

  modules = {
    home = [myHome];
    nixos = [myNixOS];
  };
}
