{
  pkgs,
  inputs,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
in {
  imports = [inputs.agenix.homeManagerModules.default];
  home.packages = [inputs.agenix.packages.${system}.default];
}
