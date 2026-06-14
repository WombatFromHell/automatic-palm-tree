# Pure functions for host discovery and enrichment, extracted from
# modules/discovery.nix so they can be unit-tested and reused independently
# of the flake-parts module system.
{lib, ...}: let
  # ── Auto-discover modules in a host directory ──────────────────────────
  # Given whether the host is a directory and its path, returns the
  # module files found by convention: nixos.nix, shared.nix, home-<user>.nix.
  autoDiscoverModules = isDir: hostDir:
    if !isDir
    then {
      nixos = [];
      shared = [];
      perUser = {};
    }
    else {
      nixos =
        lib.optional (builtins.pathExists (hostDir + "/nixos.nix"))
        (hostDir + "/nixos.nix");
      shared =
        lib.optional (builtins.pathExists (hostDir + "/shared.nix"))
        (hostDir + "/shared.nix");
      perUser = let
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

  # ── Host enrichment pipeline ───────────────────────────────────────────
  #
  # Takes a schema-evaluated host config plus auto-discovered module paths
  # and derives the merged user list, OS/HM usernames, and merged module set
  # that builders consume.
  #
  # Per-user modules come from two sources:
  #   - autoModules.perUser — discovered via home-<user>.nix files in dir hosts
  #   - evaluatedConfig.modules.perUser — declared explicitly in host files
  enrichHost = evaluatedConfig: autoModules: let
    # Union of usernames from per-user modules declared in the host directory
    # and those declared explicitly in the host file.
    allUsernames = lib.unique (
      (builtins.attrNames autoModules.perUser)
      ++ (builtins.attrNames evaluatedConfig.modules.perUser)
    );

    # Every discovered user is enabled by default; the host file can opt out.
    impliedUsers = builtins.listToAttrs (
      map (user: {
        name = user;
        value = {enabled = true;};
      })
      allUsernames
    );

    mergedUsers = lib.recursiveUpdate impliedUsers evaluatedConfig.users;
    enabledUsers = lib.filterAttrs (_: u: u.enabled) mergedUsers;
    osUsernames = lib.attrNames enabledUsers;

    # HM usernames: from the enabled set, only those with a per-user module
    # and whose hmEnabled flag hasn't been explicitly set to false.
    hmUsernames =
      builtins.filter (
        u: builtins.elem u allUsernames && (mergedUsers.${u}.hmEnabled or true)
      )
      osUsernames;

    # Merge auto-discovered modules with host-local modules.
    mergedModules = {
      nixos = autoModules.nixos ++ evaluatedConfig.modules.nixos;
      shared = autoModules.shared ++ evaluatedConfig.modules.shared;
      perUser = lib.recursiveUpdate autoModules.perUser evaluatedConfig.modules.perUser;
    };
  in {
    modules = mergedModules;
    inherit osUsernames hmUsernames mergedUsers;
  };
in {
  inherit autoDiscoverModules enrichHost;
}
