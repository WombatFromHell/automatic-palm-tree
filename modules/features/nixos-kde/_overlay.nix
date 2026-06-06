# _overlay.nix
{
  final,
  prev,
}: let
  basePkg = prev.kdePackages.plasma-workspace;

  xdgdataPkg = final.stdenv.mkDerivation {
    name = "${basePkg.name}-xdgdata";
    dontUnpack = true;
    dontFixup = true;
    dontWrapQtApps = true;
    installPhase = ''
      mkdir -p $out/share
      pushd $out/share > /dev/null

      IFS=:
      for DIR in $XDG_DATA_DIRS; do
        if [[ -d "$DIR" ]]; then
          for ITEM in "$DIR"/*; do
            if [[ -e "$ITEM" && ! -e "''${ITEM##*/}" ]]; then
              ln -s "$ITEM" "''${ITEM##*/}"
            fi
          done
        fi
      done

      popd > /dev/null
    '';
  };

  overriddenWorkspace = basePkg.overrideAttrs {
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
in {
  kdePackages =
    prev.kdePackages
    // {
      plasma-workspace = overriddenWorkspace;
      plasma-workspace-xdgdata = xdgdataPkg;
    };
}
