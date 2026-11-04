# expect: Unknown feature
# A feature name with no features/ directory must be rejected at eval time,
# not quietly dropped from the module list.
(import ../support.nix).features.resolveFeaturePaths ["definitely-not-a-feature"] "nixos"
