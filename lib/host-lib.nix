# Helpers handed to host files (as `hostLib`) for composing host definitions.
{lib, ...}: let
  inherit (lib) isAttrs isList isDerivation mapAttrs unique;

  # Module-system wrappers (mkForce, mkIf, ...) and derivations are leaves.
  isLeaf = v: !(isAttrs v) || v ? _type || isDerivation v;

  mergeValue = l: r:
    if isList l && isList r
    then unique (l ++ r)
    else if !(isLeaf l) && !(isLeaf r)
    then mergeAttrs l r
    else r;

  mergeAttrs = l: r:
    l
    // mapAttrs (n: rv:
      if l ? ${n}
      then mergeValue l.${n} rv
      else rv)
    r;

  # mergeModules base override: `override` wins on scalars, extends lists/attrsets.
  mergeModules = lib.foldl' mergeAttrs {};

  # mergeHome [profiles...]: mergeModules for a standalone Home Manager host (no NixOS).
  # Forces isNixOS off, drops NixOS-only features, and clears isAdmin (a no-op there).
  mergeHome = modules: let
    merged = mergeModules modules;
  in
    merged
    // {
      isNixOS = false;
      nixosModules = [];
      features = lib.filter (f: !lib.hasPrefix "nixos-" f) (merged.features or []);
      users = mapAttrs (_: u: u // {isAdmin = false;}) (merged.users or {});
    };

  # Drop features from a list, e.g. for a variant that must not carry a base feature.
  removeFeatures = drop: features: lib.subtractLists drop features;

  # profiles dir [names]: load <dir>/<name>.nix for each name, as a list for mergeModules.
  # Profiles get `hostLib`, so a profile can itself compose other profiles.
  profiles = dir: map (name: import (dir + "/${name}.nix") {inherit hostLib;});

  # A host-record fragment that adds one NixOS module / one user's HM module.
  nixosModule = path: {nixosModules = [path];};
  homeModule = user: path: {homeModules.${user} = [path];};

  hostLib = {inherit mergeModules mergeHome profiles removeFeatures nixosModule homeModule;};
in {
  inherit (hostLib) mergeModules mergeHome profiles removeFeatures nixosModule homeModule;
}
