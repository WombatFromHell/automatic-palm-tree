{
  lib,
  inputs,
  self,
  hostsDir,
}: let
  discovery = import ./discovery.nix {inherit lib hostsDir;};

  coreModules = [
    {
      nix.settings = {
        experimental-features = ["nix-command" "flakes"];
        bash-prompt-prefix = "(nix:$name) ";
        substituters = [
          "https://cache.nixos.org"
          "https://wombatfromhell.cachix.org/"
          "https://nix-community.cachix.org/"
          "https://cache.lix.systems/"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "wombatfromhell.cachix.org-1:pyIVJJkoLxkjH/MKK1ylrrdJKPpm+aXLeD2zAqVk9lA="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "cache.lix.systems:aBnZUw8zA7H35Cz2RyKFVs3H4PlGTLawyY5KRbvJR8o="
        ];
      };
    }
  ];

  builders = import ./builders.nix {
    inherit lib inputs self hostsDir coreModules;
  };
in {
  inherit (discovery) discoverHosts;
  inherit (builders) mkSystem mkHome buildConfigs;
  inherit coreModules;
}
