{
  config,
  lib,
  inputs,
  self,
  ...
}: let
  discovery = import ./discovery.nix {inherit lib self;};

  systemModules = [
    {
      nix.settings = {
        experimental-features = ["nix-command" "flakes"];
        bash-prompt-prefix = "(nix:$name) ";
        substituters = [
          "https://cache.nixos.org"
          "https://wombatfromhell.cachix.org/"
          "https://nix-community.cachix.org/"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "wombatfromhell.cachix.org-1:pyIVJJkoLxkjH/MKK1ylrrdJKPpm+aXLeD2zAqVk9lA="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
      };
      documentation = {
        enable = false;
        man.enable = false;
      };
    }
  ];

  builders = import ./builders {
    inherit lib inputs self systemModules;
    inherit (discovery) discoverHosts;
  };
in {
  # Merge the final configurations into the flake outputs
  config.flake = {
    nixosConfigurations = builders.buildConfigs.nixos;
    darwinConfigurations = builders.buildConfigs.darwin;
    homeConfigurations = builders.buildConfigs.home;
  };
}
