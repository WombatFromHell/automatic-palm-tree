# expect: Unknown feature
# A feature name with no features/ directory must be rejected at eval time,
# not quietly dropped from the module list.
let
  s = import ../support.nix;
in
  s.features.resolveFeaturePaths ["definitely-not-a-feature"] "nixos"
