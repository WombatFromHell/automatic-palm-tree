# expect: not a normalized path
# systemd-escape refuses a path it cannot resolve without the filesystem. The old
# slash-swap happily wrote `mnt-..-x.mount`, a unit that fails at boot with no error
# at eval, so mkUnitMounts must surface nixpkgs' own refusal instead.
let
  u = (import ../support.nix).fs.mkUnitMounts {} {"/mnt/../x" = {what = "/dev/a"; automount = true;};};
in
  builtins.head (builtins.head u.mounts).requires
