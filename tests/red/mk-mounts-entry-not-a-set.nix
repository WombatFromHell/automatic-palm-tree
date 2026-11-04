# expect: expected a set but found a string
# A mount entry is an attrset; the bare-string shorthand only exists on `mkUnitMounts`,
# so `mkMounts` must reject it instead of merging a string.
((import ../support.nix).fs.mkMounts {fsType = "ext4";} {"/m" = "/dev/x";})."/m"
