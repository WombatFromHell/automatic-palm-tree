{
  lib,
  self,
  inputs,
  hostLib,
}: let
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;

  # Accept both foo.nix files and foo/ directories containing a default.nix
  hostEntries =
    lib.filterAttrs (
      n: t:
        (t == "regular" && lib.hasSuffix ".nix" n)
        || (t == "directory" && builtins.pathExists (hostsDir + "/${n}/default.nix"))
    )
    entries;
in
  lib.mapAttrs (
    filename: type: let
      isDir = type == "directory";
      name =
        if isDir
        then filename
        else lib.removeSuffix ".nix" filename;
      path =
        if isDir
        then hostsDir + "/${filename}/default.nix"
        else hostsDir + "/${filename}";

      config = import path ({
          inherit self inputs lib;
        }
        // hostLib); # inject hmModule, nixosModule, sharedModule
    in {inherit name config;}
  )
  hostEntries
