{
  config,
  lib,
  pkgs,
  ...
}: let
  moduleName = "game-performance";
  perfBoost = import ./perfboost.nix {inherit pkgs;};
in {
  options."${moduleName}".enable = lib.mkEnableOption "Enable CachyOS-like ${moduleName} wrapper script and ananicy-cpp rules";

  config = lib.mkIf config."${moduleName}".enable {
    environment.systemPackages = [
      perfBoost.scriptContent
    ];

    services = {
      ananicy = {
        enable = true;
        package = pkgs.ananicy-cpp;
        rulesProvider = pkgs.ananicy-rules-cachyos;
        extraRules = [
          {
            "name" = "Dragon Age The Veilguard.exe";
            "type" = "Game";
          }
          {
            "name" = "TheGreatCircle.exe";
            "type" = "Game";
          }
          {
            "name" = "Avowed-Win64-Shipping.exe";
            "type" = "Game";
          }
        ];
      };
    };
  };
}
