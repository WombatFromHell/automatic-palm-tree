# expect: attribute 'system' missing
# A home configuration is not a NixOS configuration: forcing the toplevel must
# fail rather than quietly produce something buildable.
let s = import ../support.nix;
in s.flake.outputs.homeConfigurations."josh@methyl-bazzite".config.system.build.toplevel
