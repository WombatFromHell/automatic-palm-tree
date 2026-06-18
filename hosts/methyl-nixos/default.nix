_: let
  base = import ../methyl/default.nix {};
in
  base
  // {
    isQemuVM = true;
  }
