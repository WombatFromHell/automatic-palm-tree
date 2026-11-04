# expect: A definition for option `features.nixgl.wrapper' is not of type
# A wrapper name outside Home Manager's enum must fail rather than quietly fall back to mesa:
# the wrong driver set is a runtime failure, not an eval one.
((import ../support.nix).hmCfg ((import ../support.nix).fixtureHost false ["hm-nixgl"] {nixgl.wrapper = "nvofei";})).features.nixgl.wrapper
