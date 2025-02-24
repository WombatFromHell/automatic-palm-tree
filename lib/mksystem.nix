# Function to create a system configuration (NixOS or Darwin)
{
  lib,
  isDarwin,
  mkHome,
  inputs,
  ...
}: hostArgs: let
  isDarwinSystem = isDarwin hostArgs;

  # Select the appropriate inputs based on the system
  selectedNixpkgs =
    if isDarwinSystem
    then inputs.nixpkgs-darwin
    else inputs.nixpkgs;

  homeManagerModule =
    if isDarwinSystem
    then inputs.home-manager-darwin.darwinModules.home-manager
    else inputs.home-manager.nixosModules.home-manager;

  systemType =
    if isDarwinSystem
    then inputs.nix-darwin.lib.darwinSystem
    else selectedNixpkgs.lib.nixosSystem;

  baseModules = lib.flatten [
    (
      if !isDarwinSystem
      then [
        inputs.chaotic.nixosModules.default
        inputs.veridian.nixosModules.default
      ]
      else []
    )

    ({pkgs, ...}: {
      nixpkgs.overlays = [
        inputs.neovim-nightly-overlay.overlays.default
      ];
    })
  ];

  darwinModules = [
    inputs.nix-darwin.darwinModules
    ../darwin/${hostArgs.hostname}
  ];
  nixosModules = [../nixos/${hostArgs.hostname}];

  homeConfig = mkHome hostArgs hostArgs.username hostArgs.hostname;

  modules = lib.flatten [
    baseModules
    (
      if isDarwinSystem
      then darwinModules
      else nixosModules
    )
    homeManagerModule
    homeConfig
  ];
in
  systemType {
    inherit (hostArgs) system;
    inherit modules;
    pkgs = selectedNixpkgs.legacyPackages.${hostArgs.system};
    specialArgs = {inherit hostArgs inputs;};
  }
