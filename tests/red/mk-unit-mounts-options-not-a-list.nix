# expect: expected a list but found a string
# Same contract on the unit-mount path: `options` is a list before it is joined
# into the mount's comma-separated option string.
let
  s = import ../support.nix;
  fs = import ../../lib/filesystems.nix {inherit (s) lib;};
  u = fs.mkUnitMounts {} {"/mnt/x" = {options = "rw";};};
  m = builtins.head u.mounts;
in
  m.options
