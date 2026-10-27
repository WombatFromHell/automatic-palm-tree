# expect: expected a set but found an integer
# Entries are attrsets; the string shorthand is the only non-set form accepted,
# so a number must throw rather than coerce.
let
  s = import ../support.nix;
  fs = import ../../lib/filesystems.nix {inherit (s) lib;};
  u = fs.mkUnitMounts {} {"/mnt/x" = 42;};
in
  builtins.head u.mounts
