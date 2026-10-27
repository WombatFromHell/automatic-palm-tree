# expect: Only one kernel feature per host
# Two kernel-pinning features in one host list is an authoring error. The module system only
# reports it as "boot.kernelPackages is defined multiple times" with two store paths and no
# host name, so the guard names the host list instead.
let
  s = import ../support.nix;
in
  s.features.resolveFeaturePaths ["nixos-cachyos" "nixos-kait2en"] "nixos"
