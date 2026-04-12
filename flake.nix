{
  description = "Unified Nix (Linux/Darwin) and Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    ...
  }: let
    lib = nixpkgs.lib;

    # ── Dendritic host discovery ──────────────────────────────────────
    # Each host directory contains:
    #   home-<user>.nix — per-user HM config (at least one required)
    #   system.nix      — optional, declares `system` attr for darwin hosts
    hostsDir = ./modules/hosts;

    # Discover all host directories automatically
    hostNames = builtins.attrNames (builtins.readDir hostsDir);

    # Discover users for a host by scanning home-*.nix files
    # Returns: [ "josh" "alex" ... ]
    getUsersForHost = name:
      lib.mapAttrsToList (name: type:
        lib.removePrefix "home-" (lib.removeSuffix ".nix" name)
      )
      (lib.filterAttrs (name: type:
        lib.hasPrefix "home-" name && lib.hasSuffix ".nix" name
      ) (builtins.readDir (hostsDir + "/${name}")));

    # Extract `system` from system.nix if it exists, otherwise default to linux
    getSystemForHost = name: let
      systemFile = hostsDir + "/${name}/system.nix";
    in
      if builtins.pathExists systemFile
      then (import systemFile).system or "x86_64-linux"
      else "x86_64-linux";

    # Build hostArgs from inferred metadata
    buildHostArgs = name: user: {
      hostname = name;
      system = getSystemForHost name;
      username = user;
    };

    # Build a flat list of { name, user, hostArgs } entries
    hostUserEntries =
      lib.concatMap (
        name: let
          users = getUsersForHost name;
        in
          map (user: {
            name = name;
            user = user;
            hostArgs = buildHostArgs name user;
          }) users
      )
      hostNames;

    # Auto-detect hostType from system string + system.nix presence
    hasSystemFile = name: builtins.pathExists (hostsDir + "/${name}/system.nix");
    inferHostType = name: let
      sys = getSystemForHost name;
    in
      if hasSystemFile name then
        if lib.hasSuffix "-darwin" sys then "darwin"
        else "nixos"
      else "home";

    nixosHosts = lib.filter (n: inferHostType n == "nixos") hostNames;
    darwinHosts = lib.filter (n: inferHostType n == "darwin") hostNames;

    # ── Module builders ─────────────────────────────────────────────

    # Host's system.nix (optional) — returns empty list if absent
    # The module function is extracted separately for metadata evaluation
    getSystemModule = name: let
      systemFile = hostsDir + "/${name}/system.nix";
    in
      if builtins.pathExists systemFile
      then [(import systemFile).module]
      else [];

    # Per-user module — always exists (at least one per host)
    mkHostHomeModule = name: user: [
      (hostsDir + "/${name}/home-${user}.nix")
    ];

    # Resolve the correct nixpkgs for a host based on its system string
    pkgsFor = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    # ── System builders ─────────────────────────────────────────────

    # Shared home-manager module — used by both mkNixOS and mkDarwin
    mkHomeManagerModule = name: users: hostArgs: {
      home-manager = {
        extraSpecialArgs = { inherit self inputs hostArgs; };
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "hm";
        users = lib.listToAttrs (map (user:
          lib.nameValuePair user {
            imports = [{ home.username = user; }] ++ mkHostHomeModule name user;
          }
        ) users);
      };
    };

    mkNixOS = name: let
      users = getUsersForHost name;
      hostArgs = buildHostArgs name (lib.head users);
    in
      lib.nixosSystem {
        system = hostArgs.system;
        modules = (getSystemModule name) ++ [ (mkHomeManagerModule name users hostArgs) ];
        specialArgs = { inherit self inputs hostArgs; };
      };

    mkDarwin = name: let
      users = getUsersForHost name;
      hostArgs = buildHostArgs name (lib.head users);
    in
      inputs.nix-darwin.lib.darwinSystem {
        system = hostArgs.system;
        modules =
          (getSystemModule name)
          ++ [
            inputs.home-manager.darwinModules.home-manager
            (mkHomeManagerModule name users hostArgs)
          ];
        specialArgs = { inherit self inputs hostArgs; };
      };

    # ── Home-manager builder ────────────────────────────────────────

    mkHomeConfig = name: user: let
      hostArgs = buildHostArgs name user;
    in
      inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor hostArgs.system;
        extraSpecialArgs = {inherit self inputs hostArgs;};
        modules =
          [{ home.username = user; }]
          ++ mkHostHomeModule name user;
      };

    # Build homeConfigurations entries
    mkHomeEntries =
      lib.listToAttrs (map ({ name, user, ... }:
        lib.nameValuePair "${user}@${name}" (mkHomeConfig name user)
      ) hostUserEntries);

    # Auto-detect current host + user for `home-manager switch --flake .#default`
    currentHostname = let
      h = builtins.getEnv "HOSTNAME";
    in if h != "" then h else builtins.getEnv "HOST";
    currentUser = builtins.getEnv "USER";
    currentHostUserEntry =
      lib.findFirst (
        { name, user, ... }:
          name == currentHostname && user == currentUser
      )
      null
      hostUserEntries;

    defaultHomeConfigAttr =
      if currentHostUserEntry != null
      then { "${currentUser}@${currentHostUserEntry.name}" = mkHomeConfig currentHostUserEntry.name currentHostUserEntry.user; }
      else {};

    allSystems = lib.lists.unique (map ({ name, ... }: getSystemForHost name) hostUserEntries);
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = builtins.filter (s: s != null) allSystems;

      flake = {
        lib = {
          inherit getSystemForHost getSystemModule mkHostHomeModule mkHomeManagerModule
            getUsersForHost buildHostArgs inferHostType hasSystemFile;
        };
        homeManagerModules.default = ./modules/home-manager;
        nixosModules.default = {
          imports = [ ./modules/core ];
        };
        darwinModules.default = {
          imports = [ ./modules/darwin ];
        };

        nixosConfigurations = lib.genAttrs nixosHosts mkNixOS;
        darwinConfigurations = lib.genAttrs darwinHosts mkDarwin;
        homeConfigurations =
          mkHomeEntries
          // defaultHomeConfigAttr;
      };
    };
}
