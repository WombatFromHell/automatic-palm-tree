# Consolidated builder utilities: package set construction, unfree schema,
# host module resolution, and user module generation.
{
  lib,
  self,
}: let
  # ── Unfree declaration schema ──────────────────────────────────────────────
  mkUnfreeOptionsModule = {
    options.unfree = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
      description = "Unfree packages permitted from pkgs and pkgsUnstable.";
    };
  };

  # ── Package set factory ────────────────────────────────────────────────────
  mkPkgs = pkgsInput: system: unfree: overlays:
    import pkgsInput {
      inherit system overlays;
      config.allowUnfreePredicate = let
        u = builtins.listToAttrs (map (n: {
            name = n;
            value = true;
          })
          unfree);
      in
        pkg: u ? ${lib.getName pkg};
    };

  # ── Host module resolution ─────────────────────────────────────────────────
  resolveHostModules = host: platform:
    (host.modules.${platform} or []) ++ (host.modules.shared or []);

  # ── NixOS user module builder ──────────────────────────────────────────────
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

  # ── Home Manager user module builder ───────────────────────────────────────
  mkUserHomeModule = {
    user,
    host,
  }: {
    imports = lib.flatten [
      host.homeModules
      (resolveHostModules host "home")
      (host.modules.perUser.${user} or [])
      mkUnfreeOptionsModule
      self.flakeModules.home-manager
    ];
    home.username = user;
    home.homeDirectory = "/home/${user}";
  };
in {
  inherit
    mkUnfreeOptionsModule
    mkPkgs
    resolveHostModules
    mkNixosUserModule
    mkUserHomeModule
    ;
}
