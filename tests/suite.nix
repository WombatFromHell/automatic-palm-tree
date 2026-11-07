# nix-unit entry point: every eval-tier assertion in one attrset, so the tier runs in a single
# process and a failing attribute prints its own diff while the rest keep running.
#
# nix-unit only treats attributes named `test*` as tests, so a suite file that defines none would
# pass vacuously (0/0 successful, exit 0). The two tripwires below are what make that impossible;
# their names are reserved and must not appear in any suite file.
#
# Each file is imported, not evaluated here, so the suite's own fixture bindings stay with it.
let
  s = import ./support.nix;
  inherit (s) lib;

  parts = [
    (import ./filesystems.nix)
    (import ./package-flags.nix)
    (import ./pins.nix)
    (import ./caches.nix)
    (import ./disko.nix)
    (import ./warnings.nix)
    (import ./ptrace.nix)
    (import ./zram.nix)
    (import ./oomd.nix)
    (import ./loader.nix)
  ];

  names = lib.concatLists (map builtins.attrNames parts);
  # `//` silently drops a repeated name, so a collision between suite files is a lost test.
  duplicated = lib.filter (n: builtins.length (lib.filter (m: m == n) names) > 1) names;
in
  lib.foldl' (a: b: a // b) {} parts
  // {
    testEverySuiteFileContributesAttributes = {
      expr = lib.filter (p: builtins.attrNames p == []) parts;
      expected = [];
    };
    testAttributeNamesAreUnique = {
      expr = lib.unique duplicated;
      expected = [];
    };
  }
