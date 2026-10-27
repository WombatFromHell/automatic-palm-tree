# expect: expected a set but found a string
# A mount entry is an attrset; the bare-string shorthand only exists on
# `mkUnitMounts`, so `mkMounts` must reject it instead of merging a string.
let
  s = import ../support.nix;
  fs = import ../../lib/filesystems.nix {inherit (s) lib;};
  m = fs.mkMounts {fsType = "ext4";} {"/m" = "/dev/x";};
in
  m."/m"
