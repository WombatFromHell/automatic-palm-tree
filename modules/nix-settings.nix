# modules/nix-settings.nix
{
  lib,
  pkgs,
  ...
}: {
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    bash-prompt-prefix = "(nix:$name) ";

    substituters = [
      "https://wombatfromhell.cachix.org/"
      "https://nix-community.cachix.org/"
      "https://attic.xuyh0120.win/lantian"
    ];
    trusted-public-keys = [
      "wombatfromhell.cachix.org-1:pyIVJJkoLxkjH/MKK1ylrrdJKPpm+aXLeD2zAqVk9lA="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
    ];
    trusted-users = ["@wheel"];
  };

  # Home Manager strictly requires `nix.package` to be set when using `nix.settings`.
  # NixOS also supports this option. Using `lib.mkDefault` satisfies HM's assertion
  # without overriding a host's explicit choice if they define a custom nix package.
  nix.package = lib.mkDefault pkgs.nix;
}
