# The warnings gate (modules/warnings-gate.nix): any configuration warning must fail a build.
# A bare module eval — no NixOS, no build, and it never forces a real host's config, so the
# ~2GB that forcing `config.warnings` costs on a host is not paid here.
let
  core = import ./support.nix;
  inherit (core) lib ck suite assertWarnStubs failingAssertions;

  eval = warnings:
    (lib.evalModules {
      modules = [
        assertWarnStubs
        ../modules/warnings-gate.nix
        {inherit warnings;}
      ];
    }).config;
in
  suite "warnings" [
    (ck "no warnings leaves the gate's assertion true" (failingAssertions (eval []) == []))

    # The message is what a failing build prints, so it has to carry the warning verbatim.
    (ck "one warning fails the assertion and its message names it"
      (let
        failed = failingAssertions (eval ["flakeCache: \"https://x\" is required"]);
        lines = lib.splitString "\n" (builtins.head failed).message;
      in
        (builtins.length failed == 1)
        && (lib.head lines == "configuration warnings:")
        && (lib.hasPrefix "flakeCache: \"https://x\" is required" (lib.elemAt lines 1))))

    (ck "every warning is listed, not just the first"
      (let
        failed = failingAssertions (eval ["first warning" "second warning"]);
      in
        (builtins.length failed == 1)
        && (lib.hasSuffix "second warning" (builtins.head failed).message)))
  ]
