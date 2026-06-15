# Builder-facing helpers extracted from host-context.nix.
#
# These functions are the minimal surface that builders (nixos.nix,
# home-manager.nix) need. They consume the pre-built host context
# rather than constructing it themselves.
{
  lib,
  self,
}: let
  pkgsLib = import ./pkgs.nix {inherit lib;};

  # Resolve host-local modules for a given platform.
  resolveHostModules = host: platform:
    (host.modules.${platform} or []) ++ (host.modules.shared or []);

  # Build the NixOS users module for a host's osUsernames.
  mkNixosUserModule = host: {lib, ...}: {
    users.users = lib.genAttrs host.osUsernames (username: let
      userCfg = host.users.${username} or {};
    in {
      isNormalUser = true;
      home = "/home/${username}";
      extraGroups =
        ["networkmanager"]
        ++ lib.optional (userCfg.isAdmin or false) "wheel";
    });
  };

  # Build the home-manager module for a single user.
  mkUserHomeModule = {
    user,
    host,
  }: {
    imports = lib.flatten [
      host.homeModules
      (resolveHostModules host "home")
      (host.modules.perUser.${user} or [])
      pkgsLib.mkUnfreeOptionsModule
      self.flakeModules.home-manager
    ];
    home.username = user;
    home.homeDirectory = "/home/${user}";
  };
in {
  inherit resolveHostModules mkNixosUserModule mkUserHomeModule;
}
