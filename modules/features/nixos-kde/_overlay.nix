# https://old.reddit.com/r/NixOS/comments/1pdtc3v/kde_plasma_is_slow_compared_to_any_other_distro/
# https://github.com/NixOS/nixpkgs/issues/126590#issuecomment-3694376547
{
  final,
  prev,
}: {
  kdePackages = prev.kdePackages.overrideScope (kdeFinal: kdePrev: let
    basePkg = kdePrev.plasma-workspace;

    # 1. Create a single aggregated directory of all 'share' dependencies
    xdgdataPkg = final.stdenv.mkDerivation {
      name = "${basePkg.name}-xdgdata";

      # Inherit dependencies so we can iterate over them in installPhase
      buildInputs = basePkg.buildInputs or [];
      propagatedBuildInputs = basePkg.propagatedBuildInputs or [];
      nativeBuildInputs = basePkg.nativeBuildInputs or [];

      dontUnpack = true;
      dontFixup = true;
      dontWrapQtApps = true;

      installPhase = ''
        mkdir -p "$out/share"

        # Include basePkg's own share directory first
        if [[ -d "${basePkg}/share" ]]; then
          ${final.lib.getExe final.lndir} -silent "${basePkg}/share" "$out/share"
        fi

        # Iterate over actual build-time dependencies (NOT the runtime $XDG_DATA_DIRS)
        for pkg in $buildInputs $propagatedBuildInputs $nativeBuildInputs; do
          if [[ -d "$pkg/share" ]]; then
            ${final.lib.getExe final.lndir} -silent "$pkg/share" "$out/share"
          fi
        done
      '';
    };

    # 2. Override plasma-workspace to use the aggregated directory
    overriddenWorkspace = basePkg.overrideAttrs (old: {
      # Use (old.preFixup or "") to APPEND rather than replace the phase
      preFixup =
        (old.preFixup or "")
        + ''
          # Safely filter out existing XDG_DATA_DIRS prefixes from qtWrapperArgs
          local newArgs=()
          local i=0
          while [[ $i -lt ''${#qtWrapperArgs[@]} ]]; do
            if [[ "''${qtWrapperArgs[$i]}" == "--prefix" ]] && [[ "''${qtWrapperArgs[$((i+1))]}" == "XDG_DATA_DIRS" ]]; then
              # Skip the 4 elements: --prefix, XDG_DATA_DIRS, separator (:), and the path
              i=$((i + 4))
            else
              newArgs+=("''${qtWrapperArgs[$i]}")
              i=$((i + 1))
            fi
          done
          qtWrapperArgs=("''${newArgs[@]}")

          # Add our aggregated directory and the package's own share directory
          qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "${xdgdataPkg}/share")
          qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "$out/share")
        '';
    });
  in {
    plasma-workspace = overriddenWorkspace;
  });
}
