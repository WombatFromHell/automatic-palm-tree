# Workaround for KDE Plasma 6.x slow startup / environment variable issue.
#
# In NixOS, wrapping Qt applications injects massive paths into XDG_DATA_DIRS.
# Plasma-workspace processes this huge string on every launch, causing significant delays.
# This overlay merges those paths into a single store directory at build time,
# drastically reducing the string size Plasma has to parse at runtime.
#
# Ref: https://old.reddit.com/r/NixOS/comments/1pdtc3v/kde_plasma_is_slow_compared_to_any_other_distro/
# Ref: https://github.com/NixOS/nixpkgs/issues/126590#issuecomment-3194531220
_: {
  nixpkgs.overlays = [
    (final: prev: {
      kdePackages = prev.kdePackages.overrideScope (
        kdeFinal: kdePrev: {
          plasma-workspace = let
            # The package we want to override
            basePkg = kdePrev.plasma-workspace;

            # Helper package that merges all XDG_DATA_DIRS into a single directory
            xdgdataPkg = final.stdenv.mkDerivation {
              name = "${basePkg.name}-xdgdata";
              buildInputs = [basePkg];
              dontUnpack = true;
              dontFixup = true;
              dontWrapQtApps = true;
              installPhase = ''
                mkdir -p $out/share
                ( IFS=:
                  for DIR in $XDG_DATA_DIRS; do
                    if [[ -d "$DIR" ]]; then
                      ${prev.lib.getExe prev.lndir} -silent "$DIR" $out
                    fi
                  done
                )
              '';
            };

            # Undo the XDG_DATA_DIRS injection that is usually done in the qt wrapper
            # script and instead inject the path of the above helper package
            derivedPkg = basePkg.overrideAttrs {
              preFixup = ''
                for index in "''${!qtWrapperArgs[@]}"; do
                  if [[ ''${qtWrapperArgs[$((index+0))]} == "--prefix" ]] && [[ ''${qtWrapperArgs[$((index+1))]} == "XDG_DATA_DIRS" ]]; then
                    unset -v "qtWrapperArgs[$((index+0))]"
                    unset -v "qtWrapperArgs[$((index+1))]"
                    unset -v "qtWrapperArgs[$((index+2))]"
                    unset -v "qtWrapperArgs[$((index+3))]"
                  fi
                done
                qtWrapperArgs=("''${qtWrapperArgs[@]}")
                qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "${xdgdataPkg}/share")
                qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "$out/share")
              '';
            };
          in
            derivedPkg;
        }
      );
    })
  ];
}
