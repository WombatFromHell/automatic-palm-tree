# Flake-parts module that discovers hosts under ./hosts/, validates them
# against lib/host-schema.nix, and exposes the enriched result as the
# discoveredHosts option consumed by the builders.
#
# Pure discovery logic lives in lib/host-discovery.nix; this file is the
# thin module-system wrapper around it.
{
  lib,
  self,
  inputs,
  ...
}: let
  hostDiscovery = import ../lib/host-discovery.nix {inherit lib;};

  # Imported here (once) so mkHostContext runs during discovery instead of
  # being repeated in every builder. Host entries carry the pre-computed
  # context fields directly.
  hostCtx = import ../lib/host-context.nix {inherit lib self inputs;};

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
    description = "Auto-discovered and enriched host configurations.";
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

        # 2. Evaluate the full config against the strict schema
        evaluatedHost = lib.evalModules {
          modules = [
            ../lib/host-schema.nix
            rawHostConfig
          ];
        };

        # 3. Auto-discover modules in the host directory
        hostDir =
          if isDir
          then hostsDir + "/${filename}"
          else null;

        autoModules = hostDiscovery.autoDiscoverModules isDir hostDir;

        # 4. Enrich: derive usernames, merge auto-discovered + host-local modules
        enriched = hostDiscovery.enrichHost evaluatedHost.config autoModules;

        # 5. Pre-build host context: feature resolution, unfree collection,
        #    and package sets — computed once here, consumed by all builders.
        hostWithEnriched = evaluatedHost.config // enriched;
        ctx = hostCtx.mkHostContext hostWithEnriched;
      in
        hostWithEnriched
        // {
          inherit name;
          inherit (ctx) pkgsStable pkgsUnstable allUnfree nixosModules homeModules nixosOverlays homeOverlays;
        }
    )
    hostEntries;
}
