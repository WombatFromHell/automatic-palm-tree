{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.dmemcg-booster;
  dmemcgPkg = pkgs.callPackage ./_package.nix {};
in {
  options.features.dmemcg-booster = {
    enable = lib.mkEnableOption "dmemcg-booster: dmemcg protection for foreground vram when gaming";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [dmemcgPkg];

    systemd.services.dmemcg-booster = {
      description = "dmemcg protection for foreground vram when gaming (system-level)";
      serviceConfig.ExecStart = "${dmemcgPkg}/bin/dmemcg-booster --use-system-bus";
      wantedBy = ["multi-user.target"];
    };
  };
}
