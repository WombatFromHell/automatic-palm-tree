# Shared plumbing for the eval-only suites in tests/.
# Nothing here builds: assertions force option values, never derivations.
#
# `builtins.tryEval` cannot gate on errors in this Nix (a deferred error is a
# value, so tryEval reports success), so "this must throw" checks live in
# tests/red/ and are gated on the exit status by tests/run.sh.
let
  root = ../.;
  flake = builtins.getFlake (toString root);
  lib = flake.inputs.nixpkgs.lib;
  inherit (import ../lib/host-options.nix {inherit lib;}) hostOptions;
  hostLib = import ../lib/host-lib.nix {inherit lib;};
  features = import ../lib/features.nix {
    inherit lib;
    self = root;
  };
  # lib/hosts.nix rooted somewhere else, so fixture hosts load in isolation.
  hostsAt = dir:
    import ../lib/hosts.nix {
      inherit lib hostLib hostOptions;
      self = dir;
    };
in {
  inherit lib flake features hostLib hostsAt;
  hosts = hostsAt root;

  # Whether a config carries a package by name. The name lives on the derivation
  # (`pname`, falling back to `name`); `set ? name` only accepts a literal path.
  # An attrset key is not in scope inside the attrset, so this is one binding.
  hasPkg = ps: name: lib.elem name (map (p: p.pname or p.name) ps);

  # A check is {name, ok}. A false `ok` is collected and reported together;
  # an expression that throws fails the suite loudly, which is the point.
  ck = name: cond: {
    inherit name;
    ok = cond;
  };

  # A suite prints "OK <name>" or throws naming every failing check.
  suite = name: checks: let
    failed = map (c: c.name) (builtins.filter (c: !c.ok) checks);
  in
    if failed == []
    then "OK ${name}"
    else throw "${name}: FAILED ${lib.concatStringsSep ", " failed}";
}
