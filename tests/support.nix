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
  # A let binding, not an attrset member, so fixtureHost below can pass it to the builders.
  pkgsSet =
    (import ../lib/default.nix {
      inherit lib;
      self = root;
      inherit (flake) inputs;
    }).pkgsFor.x86_64-linux;

  # lib/builders.nix itself, so a fixture host resolves its modules, narrows host facts and
  # gets specialArgs exactly as production does — a hand-written module list here would be a
  # second copy of the builder.
  builders = import ../lib/builders.nix {
    inherit lib features flakeHostOptions;
    inherit (flake) inputs;
    self = root;
  };

  # A fixture host record shaped like lib/hosts.nix's output: featureNames are the features to
  # import, featureValues the feature option values to set. isNixOS drives hm-nixgl's disable
  # branch and whether josh is an admin.
  fixtureHost = isNixOS: featureNames: featureValues: {
    name = "fixture";
    system = "x86_64-linux";
    inherit isNixOS;
    features = featureNames;
    users.josh = {isAdmin = isNixOS;};
    osUsernames = ["josh"];
    adminUsernames = lib.optionals isNixOS ["josh"];
    hmUsernames = ["josh"];
    pkgs = pkgsSet;
    nixosModules = [];
    homeModules.josh = [{features = featureValues;}];
  };

  # lib/filesystems.nix, exported so the suites and the builders' specialArgs read one module
  # set instead of re-importing it. Lazy.
  fs = import ../lib/filesystems.nix {
    inherit lib;
    nixpkgs = flake.inputs.nixpkgs;
  };

  # The derivations our feature _package.nix files produce, called exactly as production does
  # (hm-brave reads pkgs.unstable, hm-zed picks the noFHS variant). Written once for wrap.nix,
  # home.nix and configs.nix; forcing only pname/outPath builds nothing.
  rawFeaturePkgs = {
    brave = pkgsSet.unstable.callPackage ../features/hm-brave/_package.nix {};
    zed = (pkgsSet.callPackage ../features/hm-zed/_package.nix {}).noFHS;
    ghostty = pkgsSet.callPackage ../features/hm-ghostty/_package.nix {};
  };

  # The Home Manager config a host's `josh` user ends up with, on both sides of the builder: a
  # standalone host builds a homeConfiguration, a NixOS host has the same config under
  # `home-manager.users.josh`. Lazy — a suite that never forces it pays nothing.
  hmCfg = host:
    if host.isNixOS
    then (builders.buildNixosConfigurations {"${host.name}" = host;}).${host.name}.config.home-manager.users.josh
    else (builders.buildHomeConfigurations {"${host.name}" = host;})."josh@${host.name}".config;
  # Options NixOS and Home Manager declare but a bare `lib.evalModules` does not: a unit test
  # of a module that writes warnings or assertions has to declare them to read them back.
  # Types match the real ones closely enough.
  # `config.flakeHost` is a host fact NixOS hosts get from lib/builders.nix; a bare
  # evalModules has no such option, so a feature module that reads it needs this stub.
  flakeHostStub = {
    options.flakeHost = lib.mkOption {
      type = lib.types.submodule {
        options.isQemuVM = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
      };
      default = {};
    };
  };

  # Option paths the desktop feature modules write (nixos-kde, nixos-gnome). NixOS declares
  # these; a bare `lib.evalModules` does not, and an undefined option is an eval error.
  desktopStubs = let
    boolOpt = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    strOpt = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
  in {
    options = {
      services = {
        xserver = {
          enable = boolOpt;
          xkb = {
            layout = strOpt;
            variant = strOpt;
          };
        };
        displayManager = {
          gdm.enable = boolOpt;
          sddm = {
            enable = boolOpt;
            wayland.enable = boolOpt;
          };
        };
        desktopManager = {
          plasma6.enable = boolOpt;
          gnome.enable = boolOpt;
        };
        gnome.gnome-keyring.enable = boolOpt;
      };
      programs.dconf.enable = boolOpt;
      # gnome.nix hands a package here; attrs keeps the check satisfied without
      # instantiating anything.
      environment.systemPackages = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
      };
    };
  };

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
  inherit lib flake features featuresAt hostLib hostsAt fixtureHost builders hmCfg assertWarnStubs flakeHostStub desktopStubs failingAssertions hasPkg ck suite fs rawFeaturePkgs;
  hosts = hostsAt root;
  pkgs = pkgsSet;
}
