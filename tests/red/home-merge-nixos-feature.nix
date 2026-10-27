# expect: NixOS-only feature
# mergeHome must reject a NixOS-only feature rather than drop it: silently removing
# it turns a mistake into a home config that quietly lacks a module.
let
  s = import ../support.nix;
in
  s.hostLib.mergeHome [{features = ["nixos-kde" "hm-base"];}]
