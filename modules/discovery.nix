# Flake-parts module that discovers hosts under ./hosts/, validates them
# against lib/host-schema.nix, and exposes the pure metadata as the
# discoveredHosts option consumed by the builders.
{
  lib,
  self,
  ...
}: let
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;

  hostEntries =
    lib.filterAttrs (
      n: t:
        (t == "regular" && lib.hasSuffix ".nix" n)
        || (t == "directory" && builtins.pathExists (hostsDir + "/${n}/default.nix"))
    )
    entries;

  # ── Pipeline steps ────────────────────────────────────────────────────
  parseHostEntry = filename: type: {
    isDir = type == "directory";
    name =
      if type == "directory"
      then filename
      else lib.removeSuffix ".nix" filename;
    path =
      if type == "directory"
      then hostsDir + "/${filename}/default.nix"
      else hostsDir + "/${filename}";
    hostDir =
      if type == "directory"
      then hostsDir + "/${filename}"
      else null;
  };

  validateHost = path:
    lib.evalModules {
      modules = [
        ../lib/host-schema.nix
        (import path {inherit self lib;})
      ];
    };

  # ── Inlined from lib/host-discovery.nix ───────────────────────────────
  autoDiscoverModules = isDir: hostDir:
    if !isDir
    then {
      nixosModules = [];
      sharedModules = [];
      homeModules = {};
    }
    else {
      nixosModules =
        lib.optional (builtins.pathExists (hostDir + "/nixos.nix"))
        (hostDir + "/nixos.nix");
      sharedModules =
        lib.optional (builtins.pathExists (hostDir + "/shared.nix"))
        (hostDir + "/shared.nix");
      homeModules = let
        dirEntries = builtins.readDir hostDir;
        homeFiles =
          lib.filterAttrs (
            n: t:
              t
              == "regular"
              && lib.hasPrefix "home-" n
              && lib.hasSuffix ".nix" n
          )
          dirEntries;
      in
        builtins.listToAttrs (
          map (
            filename: let
              user = lib.removeSuffix ".nix" (lib.removePrefix "home-" filename);
            in
              lib.nameValuePair user [(hostDir + "/${filename}")]
          ) (builtins.attrNames homeFiles)
        );
    };

  enrichHost = evaluatedConfig: autoModules: let
    allUsernames = lib.unique (
      (builtins.attrNames autoModules.homeModules)
      ++ (builtins.attrNames evaluatedConfig.homeModules)
    );
    impliedUsers = builtins.listToAttrs (
      map (user: {
        name = user;
        value = {enabled = true;};
      })
      allUsernames
    );
    mergedUsers = impliedUsers // evaluatedConfig.users;
    enabledUsers = lib.filterAttrs (_: u: u.enabled) mergedUsers;
    osUsernames = lib.attrNames enabledUsers;
    hmUsernames =
      builtins.filter (
        u:
          (autoModules.homeModules ? ${u} || evaluatedConfig.homeModules ? ${u})
          && (mergedUsers.${u}.hmEnabled or true)
      )
      osUsernames;
  in {
    nixosModules = autoModules.nixosModules ++ evaluatedConfig.nixosModules;
    sharedModules = autoModules.sharedModules ++ evaluatedConfig.sharedModules;
    homeModules = autoModules.homeModules // evaluatedConfig.homeModules;
    inherit osUsernames hmUsernames;
  };
  # ──────────────────────────────────────────────────────────────────────

  buildHost = filename: type: let
    entry = parseHostEntry filename type;
    inherit (entry) isDir name path hostDir;
    evaluatedHost = validateHost path;
    cfg = evaluatedHost.config;
    autoModules = autoDiscoverModules isDir hostDir;
    enriched = enrichHost cfg autoModules;
    adminNames = lib.filter (name: cfg.users.${name}.isAdmin) (builtins.attrNames cfg.users);
    check =
      if !cfg.isNixOS && adminNames != []
      then
        builtins.warn
        (
          "${name}: 'isNixOS = false', but users.${lib.concatStringsSep ", " adminNames}.isAdmin = true! "
          + "This is a no-op on standalone home-manager hosts."
        )
        {}
      else {};
  in
    cfg // enriched // check // {inherit name;};
in {
  options.discoveredHosts = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    internal = true;
    default = {};
    description = "Auto-discovered and enriched host metadata.";
  };

  config.discoveredHosts = lib.mapAttrs buildHost hostEntries;
}
