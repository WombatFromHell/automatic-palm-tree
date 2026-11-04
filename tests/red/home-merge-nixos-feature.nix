# expect: NixOS-only feature
# mergeHome must reject a NixOS-only feature rather than drop it: silently removing
# it turns a mistake into a home config that quietly lacks a module.
(import ../support.nix).hostLib.mergeHome [{features = ["nixos-kde" "hm-base"];}]
