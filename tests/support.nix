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
  # lib/features.nix rooted somewhere else, so a symlinked feature dir loads in isolation.
  featuresAt = dir:
    import ../lib/features.nix {
      inherit lib;
      self = dir;
    };
  # lib/hosts.nix rooted somewhere else, so fixture hosts load in isolation.
  hostsAt = dir:
    import ../lib/hosts.nix {
      inherit lib hostLib hostOptions;
      self = dir;
    };
in {
  inherit lib flake features featuresAt hostLib hostsAt;
  hosts = hostsAt root;

  # Options NixOS and Home Manager declare but a bare `lib.evalModules` does not: a unit test
  # of a module that writes warnings or assertions has to declare them to read them back.
  # Types match the real ones closely enough.
  assertWarnStubs = {
    options.warnings = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
    options.assertions = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options.assertion = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        options.message = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
      });
      default = [];
    };
  };

  # Failed assertions as data. A bare eval does not throw on them (throwing is
  # `lib.asserts.checkAssertWarn`'s job, which the build path runs), so a suite can assert on
  # the messages. Forcing a *host's* `config.assertions` would force `config.warnings` too.
  failingAssertions = cfg: builtins.filter (a: !a.assertion) cfg.assertions;

  # Whether a config carries a package by name. The name lives on the derivation
  # (`pname`, falling back to `name`); `set ? name` only accepts a literal path.
  # An attrset key is not in scope inside the attrset, so this is one binding.
  # A hit stops at the first match; a miss has to scan the whole list, which is why absence
  # is asserted elsewhere (tests/configs.nix reads namespaces, units and options).
  hasPkg = ps: name: lib.any (p: (p.pname or p.name) == name) ps;

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
