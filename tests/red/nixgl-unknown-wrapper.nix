# expect: A definition for option `features.nixgl.wrapper' is not of type
# A wrapper name outside Home Manager's enum must fail rather than quietly fall back to mesa:
# the wrong driver set is a runtime failure, not an eval one.
let
  s = import ../support.nix;
in
  (s.hmFixture false {nixgl.wrapper = "nvofei";}).features.nixgl.wrapper
