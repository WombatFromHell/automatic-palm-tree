{
  lib,
  self,
  inputs,
}: let
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;
  hostFiles =
    lib.filterAttrs (
      n: t:
        t == "regular" && lib.hasSuffix ".nix" n
    )
    entries;
in
  lib.mapAttrs (
    filename: _: let
      name = lib.removeSuffix ".nix" filename;
      config = import (hostsDir + "/${filename}") {inherit self inputs lib;};
    in {inherit name config;}
  )
  hostFiles
