# Ref: https://old.reddit.com/r/NixOS/comments/1pdtc3v/kde_plasma_is_slow_compared_to_any_other_distro/
# Ref: https://github.com/NixOS/nixpkgs/issues/126590#issuecomment-3194531220
_: {
  nixpkgs.overlays = [
    (final: prev: {
      kdePackages = prev.kdePackages.overrideScope (
        kdeFinal: kdePrev: {
          plasma-workspace = kdePrev.plasma-workspace.overrideAttrs (old: {
            # Merge XDG_DATA_DIRS at build time to avoid huge runtime strings.
            #
            # Key changes vs. original:
            #   1. xdgdataPkg is a standalone mkDerivation with NO buildInputs —
            #      it only needs lndir at build time (nativeBuildInputs).
            #      This avoids a full plasma-workspace recompile just to get dirs.
            #   2. The merge derivation runs during the *wrapper fixup* phase of
            #      this single overrideAttrs pass; XDG_DATA_DIRS is still populated
            #      by the Qt wrapper at that point so we can read it directly.
            #   3. We use a single overrideAttrs instead of two chained ones,
            #      eliminating one full Nix evaluation/build cycle.
            preFixup =
              (old.preFixup or "")
              + ''
                # Build the merged XDG data dir inline during fixup —
                # no separate derivation needed, XDG_DATA_DIRS is live here.
                mergedXdgData="$TMPDIR/merged-xdg-share"
                mkdir -p "$mergedXdgData/share"
                (
                  IFS=:
                  for DIR in $XDG_DATA_DIRS; do
                    if [[ -d "$DIR" ]]; then
                      ${prev.lib.getExe prev.lndir} -silent "$DIR" "$mergedXdgData"
                    fi
                  done
                )

                # Strip all XDG_DATA_DIRS --prefix entries injected by the Qt wrapper
                newArgs=()
                i=0
                while [[ $i -lt ''${#qtWrapperArgs[@]} ]]; do
                  if [[ ''${qtWrapperArgs[$i]} == "--prefix" ]] \
                     && [[ ''${qtWrapperArgs[$((i+1))]} == "XDG_DATA_DIRS" ]]; then
                    (( i+=4 ))  # skip: --prefix XDG_DATA_DIRS : <value>
                  else
                    newArgs+=("''${qtWrapperArgs[$i]}")
                    (( i+=1 ))
                  fi
                done
                qtWrapperArgs=("''${newArgs[@]}")

                # Copy merged tree into the output store path so it's self-contained
                # and no TMPDIR reference leaks into the wrapper.
                mergedOut="$out/share/plasma-xdg-merged"
                mkdir -p "$mergedOut"
                ${prev.lib.getExe prev.lndir} -silent "$mergedXdgData" "$out"

                qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "$out/share")
              '';
          });
        }
      );
    })
  ];
}
