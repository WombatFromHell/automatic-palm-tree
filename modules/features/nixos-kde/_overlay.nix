# https://old.reddit.com/r/NixOS/comments/1pdtc3v/kde_plasma_is_slow_compared_to_any_other_distro/
# https://github.com/NixOS/nixpkgs/issues/126590#issuecomment-3694376547
{
  final,
  prev,
}: {
  kdePackages = prev.kdePackages.overrideScope (kdeFinal: kdePrev: let
    basePkg = kdePrev.plasma-workspace;

    xdgdataPkg = final.stdenv.mkDerivation {
      name = "${basePkg.name}-xdgdata";
      buildInputs = [basePkg];
      nativeBuildInputs = [prev.lndir];
      dontUnpack = true;
      dontFixup = true;
      dontWrapQtApps = true;

      installPhase = ''
        mkdir -p "$out/share"
        ( IFS=:
          for DIR in $XDG_DATA_DIRS; do
            if [[ -d "$DIR" ]]; then
              ${prev.lib.getExe prev.lndir} -silent "$DIR" $out
            fi
          done
        )
      '';
    };

    overriddenWorkspace = basePkg.overrideAttrs {
      preFixup = ''
        for index in "''${!qtWrapperArgs[@]}"; do
          if [[ ''${qtWrapperArgs[$index]} == "--prefix" ]] \
          && [[ ''${qtWrapperArgs[$((index+1))]} == "XDG_DATA_DIRS" ]]; then
            unset -v \
              "qtWrapperArgs[$index]" \
              "qtWrapperArgs[$((index+1))]" \
              "qtWrapperArgs[$((index+2))]" \
              "qtWrapperArgs[$((index+3))]"
          fi
        done

        # Rebuild the array to remove empty indices
        qtWrapperArgs=("''${qtWrapperArgs[@]}")
        qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "${xdgdataPkg}/share")
        qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "$out/share")
      '';
    };
  in {
    plasma-workspace = overriddenWorkspace;
  });
}
