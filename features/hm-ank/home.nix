# 'ank': the Ank CLI, built from the pinned commit in ./metadata.json (see ./_package.nix).
#
# Opt-in through the host feature list (hosts/<host>/default.nix or a profile → "hm-ank"), like
# every other feature — the feature list is the gate, no extra enable flag.
#
# The binary goes on PATH through home.packages. Nothing here runs `cargo install`: that would put
# `ank` in ~/.cargo/bin, outside the store, and the update script could not keep it pinned.
#
# Skills are deliberately not installed. ~/.agents/skills is the user's own tree; the binary stamps
# the skill revision it was built alongside into `ank --version`, so the pin and the installed skill
# can be compared without this module touching either.
{pkgs, ...}: let
  # Bound, not written inside the list literal: `[f x {}]` is a three-element list in Nix, not an
  # application.
  ank = pkgs.callPackage ./_package.nix {};
in {
  home.packages = [ank];
}
