# modules/caches.nix — binary-cache registry, the one place a substituter URL + key is written.
#
# It owns `nix.settings.extra-substituters`/`extra-trusted-public-keys`, so a feature never
# declares a cache of its own and gating reads membership (`config.flakeCache.ready`) instead of a
# hand-flipped `bootstrap` flag.
#
# Substitution is opportunistic: `nix.extraOptions = "fallback = true"` (modules/defaults/nixos.nix)
# means "substitute if you can, build ourselves only if we must". A cache is only usable once the
# *live* /etc/nix/nix.conf carries its key, so the switch that ships the key builds locally and the
# next one substitutes. bootstrap.sh sidesteps that for its own switches by handing the registry's
# urls+keys to the daemon through NIX_CONFIG (nix_config()).
{
  lib,
  config,
  ...
}: let
  cfg = config.flakeCache;

  # Add a cache there, then name it in `flakeCache.enable`.
  inherit (import ./cache-registry.nix) registry;

  # What enabled features actually ask for; a required cache missing from the registry is a
  # typo, not a cache outage.
  requiredNames = lib.filterAttrs (_: r: r) cfg.required;
  unknown = lib.filterAttrs (n: _: !builtins.hasAttr n registry) requiredNames;

  # A cache a feature asked for that this host does not substitute from.
  missing = lib.filterAttrs (n: _: !lib.elem n cfg.enable) requiredNames;
  warn = n: ''
    flakeCache: "${registry.${n}.url or n}" is required by an enabled feature but this host does not
    substitute from it, so whatever that feature pulls in is built locally instead. Add "${n}" to
    `flakeCache.enable` to pull it from the cache.
  '';
in {
  options.flakeCache = {
    enable = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames registry));
      default = lib.attrNames registry;
      description = "Named caches from the registry this host substitutes from. [] builds everything locally.";
    };

    # attrset (cache -> required) so multiple features merge by key instead of last-wins, which
    # is how `extraGroups` works too (modules/feature-options.nix).
    required = lib.mkOption {
      type = lib.types.attrsOf lib.types.bool;
      default = {};
      internal = true;
      description = "Caches an enabled feature needs to pull its build inputs from.";
    };

    ready = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
      description = "Every required cache is enabled, i.e. its url and key land in /etc/nix/nix.conf.";
    };
  };

  config = {
    nix.settings.extra-substituters = map (n: registry.${n}.url) cfg.enable;
    nix.settings.extra-trusted-public-keys = map (n: registry.${n}.publicKey) cfg.enable;

    flakeCache.ready = missing == {};

    # Explains a slow build instead of just being slow: names the cache and the fix.
    warnings = map warn (lib.attrNames missing);

    assertions = [
      {
        assertion = unknown == {};
        message = "flakeCache.required names unknown cache(s) ${lib.concatStringsSep ", " (lib.attrNames unknown)}";
      }
    ];
  };
}
