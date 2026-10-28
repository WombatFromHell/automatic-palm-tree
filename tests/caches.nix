# Slice 1's contract: modules/caches.nix turns flakeCache.required into substituters, keys,
# assertions and a warning naming the cache the host needs but does not substitute from.
# A bare module eval, so no NixOS and no build — and it uses the flake's own lib, so the gate
# never resolves the registry's nixpkgs (a different rev, and a Git fetch mid-gate).
let
  core = import ./support.nix;
  inherit (core) lib ck suite assertWarnStubs failingAssertions;

  # The registry the module reads, so the expected urls/keys are the real ones.
  inherit (import ../modules/cache-registry.nix) registry;

  # Options NixOS declares and lib.evalModules does not: the module writes these, so the unit
  # test has to declare them to read them back. Stub types match the real ones closely enough.
  # (warnings/assertions come from tests/support.nix, shared with tests/warnings.nix.)
  stubs = {
    options.nix.settings.extra-substituters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
    options.nix.settings.extra-trusted-public-keys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
  };

  eval = enable: required:
    (lib.evalModules {
      modules = [
        assertWarnStubs
        stubs
        ../modules/caches.nix
        {
          flakeCache.enable = enable;
          flakeCache.required = required;
        }
      ];
    }).config;

  evalCfg = enable: required: eval enable required;
in
  suite "caches" [
    # The warning's message is a multi-line string and its first line names the url, so the
    # "which cache" check has to look at the line that carries the fix.
    (ck "a required cache the host does not substitute from is warned by name"
      (let
        cfg = evalCfg [] {nix-community = true;};
        head = builtins.head cfg.warnings;
      in
        (builtins.length cfg.warnings == 1)
        && (lib.hasPrefix "flakeCache: \"${registry.nix-community.url}\"" head)
        && (lib.any (line: lib.hasSuffix "Add \"nix-community\" to" line) (lib.splitString "\n" head))))

    (ck "a required cache that is enabled produces no warning"
      ((evalCfg ["nix-community"] {nix-community = true;}).warnings == []))

    (ck "ready is false while a required cache is disabled" (!(evalCfg [] {kait2en = true;}).flakeCache.ready))
    (ck "ready is true when every required cache is enabled"
      ((evalCfg ["kait2en" "nix-community"] {
        kait2en = true;
        nix-community = true;
      }).flakeCache.ready))
    (ck "ready is true when nothing is required" ((evalCfg [] {}).flakeCache.ready))

    (ck "a required cache outside the registry fails an assertion"
      (let
        failed = failingAssertions (evalCfg ["nix-community"] {bogus-cache = true;});
      in
        (builtins.length failed == 1)
        && (lib.hasPrefix "flakeCache.required names unknown cache(s)" (builtins.head failed).message)))

    (ck "substituters and keys come from the enabled caches in order"
      (let
        cfg = evalCfg ["nix-community" "xilopkgs"] {};
      in
        (cfg.nix.settings.extra-substituters == [registry.nix-community.url registry.xilopkgs.url])
        && (cfg.nix.settings.extra-trusted-public-keys == [registry.nix-community.publicKey registry.xilopkgs.publicKey])))

    (ck "no caches means no substituters and no keys"
      (let
        cfg = evalCfg [] {};
      in
        (cfg.nix.settings.extra-substituters == []) && (cfg.nix.settings.extra-trusted-public-keys == [])))
  ]
