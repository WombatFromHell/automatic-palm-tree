{
  lib,
  self,
  hostLib,
  hostOptions,
}: let
  # ── host discovery ──
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;

  # A host entry can be a symlink (a checkout where a host file or a whole host dir
  # points elsewhere); readDir reports "symlink", so a "regular"/"directory" filter
  # silently dropped it. A symlink counts as a directory host only if it has a
  # default.nix, exactly like a real directory.
  isHostDir = name: type:
    (type == "directory" || type == "symlink") && builtins.pathExists (hostsDir + "/${name}/default.nix");

  hostEntries =
    lib.filterAttrs (
      n: t:
        isHostDir n t
        || ((t == "regular" || t == "symlink") && lib.hasSuffix ".nix" n)
    )
    entries;

  parseHostEntry = filename: type: let
    isDir = isHostDir filename type;
  in {
    inherit isDir;
    name =
      if isDir
      then filename
      else lib.removeSuffix ".nix" filename;
    path =
      if isDir
      then hostsDir + "/${filename}/default.nix"
      else hostsDir + "/${filename}";
    hostDir =
      if isDir
      then hostsDir + "/${filename}"
      else null;
  };

  # A `home-<user>.nix` file implies that user, so its entry is authored here as
  # empty and the user submodule fills enabled/isAdmin/hmEnabled defaults.
  #
  # Returns the evaluated *config* (not the evalModules result). The error context
  # is attached to forcing that config, which is where the module system reports a
  # rejected attribute (e.g. a stray `boot`), so the failing host file is named
  # instead of `<unknown-file>`.
  validateHost = path: autoUsers: let
    evaluated = lib.evalModules {
      modules = [
        hostOptions
        {
          # Name the source file in "option does not exist" errors.
          _file = toString path;
          imports = [(import path {inherit self lib hostLib;})];
        }
        ({config, ...}: {
          users = lib.genAttrs (autoUsers ++ lib.attrNames config.homeModules) (_: {});
        })
      ];
    };
  in
    builtins.addErrorContext
    ''
      while validating host file ${toString path} against lib/host-options.nix.
      A host file is a host record (system, isNixOS, users, features, nixosModules, homeModules),
      not a NixOS module. Pass NixOS config via `nixosModules = [ ./path/to/module.nix ]`
      or `hosts/<name>/nixos.nix` instead of listing it as a profile.''
    evaluated.config;

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
              (t == "regular" || t == "symlink")
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
    # Union, not replacement: `//` dropped the discovered home-<user>.nix whenever a
    # host declared its own module for that user. hostLib.mergeModules unions the
    # per-user module lists.
    homeModules = hostLib.mergeModules [autoModules.homeModules evaluatedConfig.homeModules];
  in {
    nixosModules = autoModules.nixosModules ++ evaluatedConfig.nixosModules;
    inherit homeModules;
    osUsernames = enabledUsernames;
    # Admins are derived here, once, so host-facts and the NixOS user defaults read
    # the same list instead of each re-filtering `users`.
    adminUsernames = builtins.filter (u: evaluatedConfig.users.${u}.isAdmin) enabledUsernames;
    hmUsernames =
      builtins.filter
      (u: builtins.hasAttr u homeModules && evaluatedConfig.users.${u}.hmEnabled)
      enabledUsernames;
  };

  buildHost = entry: let
    inherit (entry) isDir name path hostDir;
    autoModules = autoDiscoverModules isDir hostDir;
    evaluatedConfig = validateHost path (builtins.attrNames autoModules.homeModules);
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
