# expect: expected a set but found an integer
# Entries are attrsets; the string shorthand is the only non-set form accepted,
# so a number must throw rather than coerce.
let
  u = (import ../support.nix).fs.mkUnitMounts {} {"/mnt/x" = 42;};
in
  builtins.head u.mounts
