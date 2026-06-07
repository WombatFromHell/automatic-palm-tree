{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.dmemcg-booster;
in {
  options.features.dmemcg-booster = {
    enable = lib.mkEnableOption "dmemcg-booster: dmemcg protection for foreground vram when gaming";
  };

  config = lib.mkIf cfg.enable {
    # Make the utility available to the user's PATH
    home.packages = [pkgs.dmemcg-booster];

    # Home Manager systemd syntax (structured INI-style)
    systemd.user.services.dmemcg-booster = {
      Unit.Description = "dmemcg protection for foreground vram when gaming (user-level)";
      Service.ExecStart = "${pkgs.dmemcg-booster}/bin/dmemcg-booster";
      Install.WantedBy = ["graphical-session-pre.target"];
    };
  };
}
