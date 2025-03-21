# Simplified function to create home-manager configurations
{
  lib,
  inputs,
  isDarwin,
  ...
}: hostArgs: let
  inherit (hostArgs) username hostname system;

  isDarwinHome = isDarwin hostArgs;
  hmOnly = hostArgs.hm-only or false;
  pkgs = import inputs.nixpkgs {
    inherit system;
    overlays = [
      inputs.neovim-nightly-overlay.overlays.default
    ];
  };

  commonModules = [
    ../home/${hostname}
    (
      if !isDarwinHome && !hmOnly
      then inputs.plasma-manager.homeManagerModules.plasma-manager
      else {}
    )
  ];
in
  if hmOnly
  then
    inputs.home-manager.lib.homeManagerConfiguration {
      # Standalone configuration
      inherit pkgs;
      extraSpecialArgs = {inherit hostArgs inputs;};
      modules = commonModules;
    }
  else {
    home-manager = {
      # Module for NixOS/Darwin
      extraSpecialArgs = {inherit hostArgs inputs;};
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "hm";
      users.${username}.imports = commonModules;
    };
  }
