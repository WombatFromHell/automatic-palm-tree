{
  config,
  lib,
  ...
}: let
  cfg = config.features.kde;
in {
  # Define the configuration options for this module
  options.features.kde = {
    enable = lib.mkEnableOption "KDE Plasma 6 desktop environment";

    overlay.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the experimental plasma-workspace overlay to unify XDG_DATA_DIRS.";
    };

    dedupEnv.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable XDG_DATA_DIRS and QT_PLUGIN_PATH deduplication at the session level.";
    };
  };

  # Apply configuration based on the options enabled above
  config = lib.mkIf cfg.enable {
    # 1. Base KDE Desktop Settings
    services = {
      displayManager.sddm.enable = true;
      desktopManager.plasma6.enable = true;
      xserver.xkb = {
        layout = "us";
        variant = "";
      };
    };

    # 2. Optional Session Command Deduplication
    environment.extraInit = lib.mkIf cfg.dedupEnv.enable ''
      if [ -n "$XDG_DATA_DIRS" ]; then
        # Deduplicate XDG_DATA_DIRS while preserving order
        XDG_DATA_DIRS=$(echo "$XDG_DATA_DIRS" | awk -v RS=: '!seen[$0]{vars=vars?vars":"$0:$0;seen[$0]} END{print vars}')
        export XDG_DATA_DIRS
      fi
      if [ -n "$QT_PLUGIN_PATH" ]; then
        QT_PLUGIN_PATH=$(echo "$QT_PLUGIN_PATH" | awk -v RS=: '!seen[$0]{vars=vars?vars":"$0:$0;seen[$0]} END{print vars}')
        export QT_PLUGIN_PATH
      fi
    '';

    # 3. Optional plasma-workspace Overlay
    nixpkgs.overlays = lib.mkIf cfg.overlay.enable [
      (final: prev: {
        kdePackages =
          prev.kdePackages
          // {
            plasma-workspace = let
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
            in
              basePkg.overrideAttrs {
                preFixup = ''
                  # Strip the massive XDG_DATA_DIRS injected by the Qt wrapper
                  for index in "''${!qtWrapperArgs[@]}"; do
                    if [[ ''${qtWrapperArgs[$((index+0))]} == "--prefix" ]] && [[ ''${qtWrapperArgs[$((index+1))]} == "XDG_DATA_DIRS" ]]; then
                      unset -v "qtWrapperArgs[$((index+0))]"
                      unset -v "qtWrapperArgs[$((index+1))]"
                      unset -v "qtWrapperArgs[$((index+2))]"
                      unset -v "qtWrapperArgs[$((index+3))]"
                    fi
                  done
                  qtWrapperArgs=("''${qtWrapperArgs[@]}")

                  # Inject our single merged directory
                  qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "${xdgdataPkg}/share")
                  qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "$out/share")
                '';
              };
          };
      })
    ];
  };
}
