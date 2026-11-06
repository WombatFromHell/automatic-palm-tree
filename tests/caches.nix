# nix-unit attributes for modules/caches.nix: flakeCache.required becomes substituters, keys,
# assertions and a warning naming the cache the host needs but does not substitute from.
# A bare module eval, so no NixOS and no build — and it uses the flake's own lib, so the gate
# never resolves the registry's nixpkgs (a different rev, and a Git fetch mid-gate).
let
  core = import ./support.nix;
  inherit (core) lib failingAssertions;

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
    core.bareEval [stubs ../modules/caches.nix] {
      flakeCache.enable = enable;
      flakeCache.required = required;
    } {};

  warned = eval [] {nix-community = true;};
  # The warning's message is a multi-line string and its first line names the url, so the
  # "which cache" check has to look at the line that carries the fix.
  warning = builtins.head warned.warnings;
  unknown = failingAssertions (eval ["nix-community"] {bogus-cache = true;});
  enabled = eval ["nix-community" "xilopkgs"] {};
  none = eval [] {};
in {
  testRequiredMissingCacheWarnsOnce = {
    expr = builtins.length warned.warnings;
    expected = 1;
  };
  testWarningNamesTheCacheUrl = {
    expr = lib.hasPrefix "flakeCache: \"${registry.nix-community.url}\"" warning;
    expected = true;
  };
  testWarningCarriesTheFix = {
    expr = lib.any (line: lib.hasSuffix "Add \"nix-community\" to" line) (lib.splitString "\n" warning);
    expected = true;
  };
  testEnabledCacheWarnsNothing = {
    expr = (eval ["nix-community"] {nix-community = true;}).warnings;
    expected = [];
  };
  testReadyFalseWhileRequiredCacheDisabled = {
    expr = (eval [] {kait2en = true;}).flakeCache.ready;
    expected = false;
  };
  testReadyTrueWhenEveryRequiredCacheEnabled = {
    expr =
      (eval ["kait2en" "nix-community"] {
        kait2en = true;
        nix-community = true;
      }).flakeCache.ready;
    expected = true;
  };
  testReadyTrueWhenNothingRequired = {
    expr = (eval [] {}).flakeCache.ready;
    expected = true;
  };
  testUnknownRequiredCacheFailsOneAssertion = {
    expr = builtins.length unknown;
    expected = 1;
  };
  testUnknownRequiredCacheNamesIt = {
    expr = lib.hasPrefix "flakeCache.required names unknown cache(s)" (builtins.head unknown).message;
    expected = true;
  };
  testSubstitutersComeFromEnabledCachesInOrder = {
    expr = enabled.nix.settings.extra-substituters;
    expected = [registry.nix-community.url registry.xilopkgs.url];
  };
  testKeysComeFromEnabledCachesInOrder = {
    expr = enabled.nix.settings.extra-trusted-public-keys;
    expected = [registry.nix-community.publicKey registry.xilopkgs.publicKey];
  };
  testNoCachesMeansNoSubstituters = {
    expr = none.nix.settings.extra-substituters;
    expected = [];
  };
  testNoCachesMeansNoKeys = {
    expr = none.nix.settings.extra-trusted-public-keys;
    expected = [];
  };
}
