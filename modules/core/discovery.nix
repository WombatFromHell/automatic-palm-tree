# modules/core/discovery.nix
{
  lib,
  self,
  inputs,
  ...
}: let
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;

  hostEntries =
    lib.filterAttrs (
      n: t:
        (t == "regular" && lib.hasSuffix ".nix" n)
        || (t == "directory" && builtins.pathExists (hostsDir + "/${n}/default.nix"))
    )
    entries;
in {
  options.discoveredHosts = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    internal = true;
    default = {};
  };

  config.discoveredHosts =
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

        # 1. Import the raw host file
        rawHostConfig = import path {inherit self inputs lib;};

        # 2. Extract the modules block so evalModules doesn't choke on it
        hostModules = rawHostConfig.modules or {};

        # 3. Remove it from the config before strict validation
        safeConfig = builtins.removeAttrs rawHostConfig ["modules"];

        # 4. Evaluate the safe config against the strict schema
        evaluatedHost = lib.evalModules {
          modules = [
            ./host-schema.nix
            safeConfig
          ];
        };
      in {
        inherit name;
        # 5. Stitch the untouched modules back onto the validated config
        config = evaluatedHost.config // {modules = hostModules;};
      }
    )
    hostEntries;
}
