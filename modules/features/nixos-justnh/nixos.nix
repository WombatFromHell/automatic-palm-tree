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
      variables.JUST_JUSTFILE = "/etc/Justfile";
      etc."Justfile".text = ''
        default:
        ${"\t"}@just --list
        switch:
        ${"\t"}nh os switch ${config.system.justHelper.flakeRoot}
        rswitch:
        ${"\t"}sudo nixos-rebuild switch --flake ${config.system.justHelper.flakeRoot}
        dswitch:
        ${"\t"}nh os switch -n ${config.system.justHelper.flakeRoot}
        dry:
        ${"\t"}sudo nixos-rebuild build --flake ${config.system.justHelper.flakeRoot} --show-trace
        list:
        ${"\t"}nh os info
        clean *args="--keep 3":
        ${"\t"}#!/usr/bin/env bash
        ${"\t"}set -euo pipefail
        ${"\t"}nh clean all {{args}} --optimise
      '';
    };
  };
}
