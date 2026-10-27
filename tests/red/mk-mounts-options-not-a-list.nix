# expect: expected a list but found a string
# `options` is a list; a string must throw rather than be joined into one option.
let
  s = import ../support.nix;
  fs = import ../../lib/filesystems.nix {inherit (s) lib;};
  m = fs.mkMounts {} {"/m" = {options = "noatime";};};
in
  m."/m".options
