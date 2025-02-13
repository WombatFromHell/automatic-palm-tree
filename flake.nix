{
  description = "Unified Nix (Linux/Darwin) and Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    veridian.url = "github:WombatFromHell/veridian-controller";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    home-manager,
    chaotic,
    veridian,
    ...
  }: let
    inherit (nixpkgs) lib;
    hosts = import ./shared.nix;
    # Filter only enabled hosts
    enabledHosts = lib.filterAttrs (_: v: v.enable or false) hosts;
    # Generate a unique list of systems from enabled hosts
    systems = lib.lists.unique (builtins.attrValues (builtins.mapAttrs (_: v: v.system) enabledHosts));

    mkHome = hostArgs: username: hostname: let
      homePath = path: ./home/${hostname}/${path};
    in {
      home-manager = {
        extraSpecialArgs = {inherit hostArgs;};
        useGlobalPkgs = true;
        useUserPackages = true;
        users.${username}.imports = [
          (homePath "home.nix")
        ];
      };
    };

    # Function to create a system configuration (NixOS or Darwin)
    mkSystem = hostArgs: let
      isDarwin = hostArgs.system == "x86_64-darwin";
      systemType =
        if isDarwin
        then nixpkgs.lib.darwinSystem
        else nixpkgs.lib.nixosSystem;

      baseModules = [
        chaotic.nixosModules.default
        veridian.nixosModules.default
      ];

      hostModules =
        if (hostArgs ? osModules)
        then map (path: ./nixos/${hostArgs.hostname}/${path}) hostArgs.osModules
        else [];

      homeManagerModules = [
        home-manager.nixosModules.home-manager
        (mkHome hostArgs hostArgs.username hostArgs.hostname)
      ];

      modules =
        if isDarwin
        then baseModules ++ hostModules
        else baseModules ++ hostModules ++ homeManagerModules;
    in
      systemType {
        inherit (hostArgs) system;
        inherit modules;
        specialArgs = {inherit hostArgs;};
      };
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      inherit systems;

      flake = {
        # Auto-generate system configurations for enabled hosts
        nixosConfigurations =
          builtins.mapAttrs (
            name: hostArgs:
              if hostArgs.system == "x86_64-linux"
              then mkSystem hostArgs
              else null
          )
          enabledHosts;

        darwinConfigurations =
          builtins.mapAttrs (
            name: hostArgs:
              if hostArgs.system == "x86_64-darwin"
              then mkSystem hostArgs
              else null
          )
          enabledHosts;
      };
    };
}
