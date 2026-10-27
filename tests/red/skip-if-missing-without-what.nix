# expect: attribute 'what' missing
# `skipIfMissing` writes `ConditionPathExists = what`, so it needs a device:
# without `what` the deferred error must surface at eval, not in the unit file.
let
  s = import ../support.nix;
  fs = import ../../lib/filesystems.nix {inherit (s) lib;};
  u = fs.mkUnitMounts {} {
    "/mnt/x" = {
      automount = true;
      skipIfMissing = true;
    };
  };
  m = builtins.head u.mounts;
in
  m.unitConfig.ConditionPathExists
