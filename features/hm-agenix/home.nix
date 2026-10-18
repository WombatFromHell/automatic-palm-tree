{
  pkgs,
  inputs,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
in {
  imports = [inputs.agenix.homeManagerModules.default];
  home.packages = [pkgs.flakePackages.agenix.${system}.default];
}
