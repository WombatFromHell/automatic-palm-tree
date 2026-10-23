# modules/nix-settings.nix
# Daemon settings only. Substituters and public keys belong to modules/caches.nix (the registry).
{
  lib,
  pkgs,
  ...
}: {
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    connect-timeout = 5;
    stalled-download-timeout = 10;
    download-attempts = 2;
  };

  # Home Manager strictly requires `nix.package` to be set when using `nix.settings`.
  # NixOS also supports this option. Using `lib.mkDefault` satisfies HM's assertion
  # without overriding a host's explicit choice if they define a custom nix package.
  nix.package = lib.mkDefault pkgs.nix;
}
