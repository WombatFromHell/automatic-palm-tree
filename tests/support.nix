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
  inherit (import ../lib/host-options.nix {inherit lib;}) hostOptions flakeHostOptions;
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
  # The loader's own package set, keyed by system: unfree allowed, pinMeta and flakePackages
  # injected, and `pkgs.unstable` present, so a suite can callPackage a feature's _package.nix
  # exactly as production does. Lazy — suites that never touch it pay nothing for the eval.
  # A let binding, not an attrset member, so hmFixture below can pass it to Home Manager.
  pkgsSet =
    (import ../lib/default.nix {
      inherit lib;
      self = root;
      inherit (flake) inputs;
    }).pkgsFor.x86_64-linux;

  # A fixture Home Manager configuration over typed host facts, narrowed exactly as
  # lib/builders.nix narrows them, so hm-nixgl's isNixOS guard runs through the real schema
  # rather than a stub. `features` are the feature option values to set. Lazy: a suite that
  # never forces it pays nothing. Used by tests/wrap.nix and its red guard, so the fixture is
  # written once.
  hmFixture = isNixOS: features:
    (flake.inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsSet;
      modules = [
        {
          home = {
            username = "josh";
            homeDirectory = "/home/josh";
            stateVersion = "24.11";
          };
          targets.genericLinux.enable = !isNixOS;
          inherit features;
        }
        (import ../modules/host-facts.nix {
          inherit lib flakeHostOptions;
          flakeHost =
            lib.getAttrs (lib.attrNames flakeHostOptions) {
              name = "hm-fixture";
              system = "x86_64-linux";
              inherit isNixOS;
              users.josh.isAdmin = isNixOS;
            }
            // {
              osUsernames = ["josh"];
              adminUsernames = lib.optionals isNixOS ["josh"];
              hmUsernames = ["josh"];
            };
        })
        ../modules/defaults/home-manager.nix
        ../features/hm-nixgl/home.nix
        ../features/hm-brave/home.nix
        ../features/hm-zed/home.nix
        ../features/hm-ghostty/home.nix
      ];
      extraSpecialArgs = {
        inherit (flake) inputs;
        fsLib = import ../lib/filesystems.nix {inherit lib;};
      };
    }).config;

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
in {
  inherit lib flake features featuresAt hostLib hostsAt hmFixture assertWarnStubs failingAssertions hasPkg ck suite;
  hosts = hostsAt root;
  pkgs = pkgsSet;
}
