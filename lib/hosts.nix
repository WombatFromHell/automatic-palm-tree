{
  lib,
  self,
  hostOptions,
}: let
  # ── host discovery ──
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;

  hostEntries =
    lib.filterAttrs (
      n: t:
        (t == "regular" && lib.hasSuffix ".nix" n)
        || (t == "directory" && builtins.pathExists (hostsDir + "/${n}/default.nix"))
    )
    entries;

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

  # A `home-<user>.nix` file implies that user, so its entry is authored here as
  # empty and the user submodule fills enabled/isAdmin/hmEnabled defaults.
  validateHost = path: autoUsers:
    lib.evalModules {
      modules = [
        hostOptions
        (import path {inherit self lib;})
        ({config, ...}: {
          users = lib.genAttrs (autoUsers ++ lib.attrNames config.homeModules) (_: {});
        })
      ];
    };

  autoDiscoverModules = isDir: hostDir:
    if !isDir
    then {
      nixosModules = [];
      homeModules = {};
    }
    else {
      nixosModules =
        lib.optional (builtins.pathExists (hostDir + "/nixos.nix"))
        (hostDir + "/nixos.nix");
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
    enabledUsernames = lib.attrNames (lib.filterAttrs (_: u: u.enabled) evaluatedConfig.users);
    hasHomeModule = u: autoModules.homeModules ? ${u} || evaluatedConfig.homeModules ? ${u};
  in {
    nixosModules = autoModules.nixosModules ++ evaluatedConfig.nixosModules;
    homeModules = autoModules.homeModules // evaluatedConfig.homeModules;
    osUsernames = enabledUsernames;
    hmUsernames = builtins.filter (u: hasHomeModule u && evaluatedConfig.users.${u}.hmEnabled) enabledUsernames;
  };

  buildHost = entry: let
    inherit (entry) isDir name path hostDir;
    autoModules = autoDiscoverModules isDir hostDir;
    evaluatedConfig =
      (validateHost path (builtins.attrNames autoModules.homeModules)).config;
    enrichedHost = enrichHost evaluatedConfig autoModules;
  in
    evaluatedConfig
    // enrichedHost
    // {inherit name;};

  # Hosts are keyed by their own name (`name` above, the same name `<user>@<host>`
  # uses), not by file name, so every public output agrees on one host name.
  # A flat `foo.nix` beside a `foo/` directory would silently overwrite, so
  # discovery throws instead.
  namedHosts = map (filename: let
    entry = parseHostEntry filename entries.${filename};
  in
    lib.nameValuePair entry.name (buildHost entry)) (builtins.attrNames hostEntries);
  hostNames = map (pair: pair.name) namedHosts;
  duplicateName = lib.findFirst (n: lib.count (x: x == n) hostNames > 1) null hostNames;
  discoveredHosts =
    if duplicateName != null
    then throw "Two host definitions resolve to the name '${duplicateName}' (for example hosts/${duplicateName}.nix beside hosts/${duplicateName}/default.nix): rename one."
    else builtins.listToAttrs namedHosts;
in {
  inherit discoveredHosts;
}
