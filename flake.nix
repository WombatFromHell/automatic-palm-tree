{
  description = "Unified Nix (Linux/Darwin) and Home Manager configuration";

  inputs = {
    # nixos inputs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # darwin inputs
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager-darwin = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
    };

    # shared inputs
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    ...
  }: let
    inherit (nixpkgs) lib;

    # ── Dendritic host discovery ──────────────────────────────────────
    # Each host's full config lives in its own module under
    # modules/hosts/<name>/default.nix
    hostsDir = ./modules/hosts;

    # Discover all host directories automatically
    hostNames = builtins.attrNames (builtins.readDir hostsDir);

    # Each host file returns: { hostArgs = {...}; imports = [...]; ... }
    # loadRaw uses pkgs=null since it's only for metadata extraction
    loadRaw = name: import (hostsDir + "/${name}") {
      pkgs = null;
      inherit inputs;
    };

    # getHostModule returns a wrapper module so hostArgs is consumed internally
    getHostModule = name: {
      imports = [(hostsDir + "/${name}")];
      options.hostArgs = lib.mkOption {
        type = lib.types.raw;
        default = {};
        internal = true;
      };
    };

    # Filter out hosts that declare disabled = true
    enabledHostNames =
      lib.filter (
        name: let v = (loadRaw name).disabled or null; in v == null || !v
      )
      hostNames;

    # Extract hostArgs (metadata) via loadRaw (pkgs=null is fine here)
    getHostArgs = name: (loadRaw name).hostArgs;

    # Classify by hostType declared in each module (enabled only)
    nixosHosts = lib.filter (n: ((getHostArgs n).hostType or null) == "nixos") enabledHostNames;
    darwinHosts = lib.filter (n: ((getHostArgs n).hostType or null) == "darwin") enabledHostNames;
    hmOnlyHosts = lib.filter (n: ((getHostArgs n).hostType or null) == "home") enabledHostNames;

    # ── Builders ──────────────────────────────────────────────────────

    mkNixOS = name: let
      hostArgs = getHostArgs name;
      inherit (hostArgs) system;
    in
      lib.nixosSystem {
        inherit system;
        modules = [
          (getHostModule name)
          {
            home-manager = {
              extraSpecialArgs = {inherit self inputs hostArgs;};
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "hm";
              users.${hostArgs.username}.imports = [
                ./modules/home-manager
              ];
            };
          }
        ];
        specialArgs = {inherit self inputs hostArgs;};
      };

    mkDarwin = name: let
      hostArgs = getHostArgs name;
      inherit (hostArgs) system;
    in
      inputs.nix-darwin.lib.darwinSystem {
        inherit system;
        modules = [
          (getHostModule name)
          {
            home-manager = {
              extraSpecialArgs = {inherit self inputs hostArgs;};
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "hm";
              users.${hostArgs.username}.imports = [
                ./modules/home-manager
              ];
            };
          }
        ];
        specialArgs = {inherit self inputs hostArgs;};
      };

    # nh auto-detection checks: <user>@<host>, then <host> alone.
    # We provide both keys pointing to the same config for robustness.
    mkHomeEntries =
      lib.foldl' (
        acc: name: let
          hostArgs = getHostArgs name;
          inherit (hostArgs) system;
          cfg = inputs.home-manager.lib.homeManagerConfiguration {
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
            extraSpecialArgs = {inherit self inputs hostArgs;};
            modules = [(getHostModule name)];
          };
        in
          acc
          // {
            "${hostArgs.username}@${hostArgs.hostname}" = cfg;
            "${hostArgs.hostname}" = cfg;
          }
      ) {}
      hmOnlyHosts;

    allSystems = lib.lists.unique (
      map (n: (getHostArgs n).system or null) enabledHostNames
    );
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = builtins.filter (s: s != null) allSystems;

      flake = {
        nixosConfigurations = lib.genAttrs nixosHosts mkNixOS;
        darwinConfigurations = lib.genAttrs darwinHosts mkDarwin;
        homeConfigurations = mkHomeEntries;
      };
    };
}
