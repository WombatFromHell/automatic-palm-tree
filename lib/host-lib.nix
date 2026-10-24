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
  mergeModules = mergeAttrs;

  # Drop features from a list, e.g. for a variant that must not carry a base feature.
  removeFeatures = drop: features: lib.subtractLists drop features;
in {
  inherit mergeModules removeFeatures;
}
