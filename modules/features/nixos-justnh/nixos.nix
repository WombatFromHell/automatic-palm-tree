{
  lib,
  config,
  pkgs,
  pkgsUnstable,
  ...
}: {
  options.system.justHelper.flakeRoot = lib.mkOption {
    type = lib.types.str;
    default = "~/.config/flakeroot";
    description = "Path to your NixOS flake root directory";
  };

  config = {
    programs.nh = {
      enable = true;
      package = pkgsUnstable.nh;
    };
    environment = {
      systemPackages = with pkgs; [
        just
      ];
      variables.JUST_JUSTFILE = "/etc/justfile";
      etc."justfile".text = ''
        rebuild:
        ${"\t"}nh os switch ${config.system.justHelper.flakeRoot}
        dry-build:
        ${"\t"}nh os switch --dry-run ${config.system.justHelper.flakeRoot}
        list:
        ${"\t"}nh os info
        clean:
        ${"\t"}nh clean all --keep 3 --optimise
      '';
    };
  };
}
