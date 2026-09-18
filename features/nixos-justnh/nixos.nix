{
  lib,
  config,
  pkgs,
  pkgsUnstable,
  ...
}: {
  options.features.justnh.flakeRoot = lib.mkOption {
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
        ${"\t"}nh os switch ${config.features.justnh.flakeRoot}
        rswitch:
        ${"\t"}sudo nixos-rebuild switch --flake ${config.features.justnh.flakeRoot} -L -v
        dswitch:
        ${"\t"}nh os switch -n ${config.features.justnh.flakeRoot}
        dry:
        ${"\t"}sudo nixos-rebuild build --flake ${config.features.justnh.flakeRoot} --show-trace -L -v
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
