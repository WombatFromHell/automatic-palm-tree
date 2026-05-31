# modules/core/nix-settings.nix
{
  lib,
  pkgs,
  ...
}: {
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    bash-prompt-prefix = "(nix:$name) ";

    substituters = [
      "https://cache.nixos.org"
      "https://wombatfromhell.cachix.org/"
      "https://nix-community.cachix.org/"
      "https://attic.xuyh0120.win/lantian"
      "https://install.determinate.systems"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "wombatfromhell.cachix.org-1:pyIVJJkoLxkjH/MKK1ylrrdJKPpm+aXLeD2zAqVk9lA="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
      "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
    ];
  };

  # Home Manager strictly requires `nix.package` to be set when using `nix.settings`.
  # NixOS also supports this option. Using `lib.mkDefault` satisfies HM's assertion
  # without overriding a host's explicit choice if they define a custom nix package.
  nix.package = lib.mkDefault pkgs.nix;
}
