{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.dmemcg-booster;
  overlay = import ./_overlay.nix;
  localPkgs = pkgs.extend overlay;
in {
  imports = [
    {nixpkgs.overlays = [overlay];} # expose 'pkgs.dmemcg-booster' as an overlay
  ];
  options.features.dmemcg-booster = {
    enable = lib.mkEnableOption "dmemcg-booster: dmemcg protection for foreground vram when gaming";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [localPkgs.dmemcg-booster];

    systemd.services.dmemcg-booster = {
      description = "dmemcg protection for foreground vram when gaming (system-level)";
      serviceConfig.ExecStart = "${localPkgs.dmemcg-booster}/bin/dmemcg-booster --use-system-bus";
      wantedBy = ["multi-user.target"];
    };
  };
}
