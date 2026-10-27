# Helpers handed to host files (as `hostLib`) for composing host definitions.
{lib, ...}: let
  inherit (lib) isAttrs isList isDerivation mapAttrs;

  # Module-system wrappers (mkForce, mkIf, ...) and derivations are leaves.
  isLeaf = v: !(isAttrs v) || v ? _type || isDerivation v;

  # Lists merge by first occurrence. `lib.unique` only removes *consecutive*
  # duplicates, so a profile reached through two paths would be imported twice and
  # the module system would reject the second declaration of the same option.
  mergeValue = l: r:
    if isList l && isList r
    then
      lib.foldl' (acc: x:
        if lib.elem x acc
        then acc
        else acc ++ [x])
      l
      r
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
  # Forces isNixOS off and clears isAdmin (a no-op there). A `nixos-` feature here is an
  # authoring mistake, not something that can be silently dropped and then wondered about.
  mergeHome = modules: let
    merged = mergeModules modules;
    nixosOnly = lib.filter (f: lib.hasPrefix "nixos-" f) (merged.features or []);
  in
    if nixosOnly != []
    then
      throw
      "mergeHome: ${lib.concatStringsSep ", " nixosOnly} ${
        if lib.length nixosOnly == 1
        then "is"
        else "are"
      } NixOS-only ${
        if lib.length nixosOnly == 1
        then "feature"
        else "features"
      } and cannot apply to a standalone Home Manager host; see hosts/methyl-base/standalone.nix for the home-only list"
    else
      merged
      // {
        isNixOS = false;
        nixosModules = [];
        users = mapAttrs (_: u: u // {isAdmin = false;}) (merged.users or {});
      };

  # profiles dir [names]: load <dir>/<name>.nix for each name, as a list for mergeModules.
  # Profiles get `hostLib`, so a profile can itself compose other profiles.
  profiles = dir: map (name: import (dir + "/${name}.nix") {inherit hostLib;});

  hostLib = {inherit mergeModules mergeHome profiles;};
in
  hostLib
