{pkgs, ...}: let
  scriptName = "perfboost";
  scriptContent = pkgs.writeShellScriptBin "${scriptName}" ''
    #!${pkgs.bash}/bin/bash
    #
    # modified from: https://github.com/CachyOS/CachyOS-Settings/blob/master/usr/bin/game-performance
    #
    PPCTL="${pkgs.power-profiles-daemon}/bin/powerprofilesctl"
    INHIBIT="${pkgs.systemdUkify}/bin/systemd-inhibit"
    #
    # Helper script to enable the performance gov with proton or others
    if ! command -v "$PPCTL" &>/dev/null; then
        echo "Error: powerprofilesctl not found" >&2
        exit 1
    fi
    if ! command -v "$INHIBIT" &>/dev/null; then
        echo "Error: systemd-inhibit not found" >&2
        exit 1
    fi

    # Don't fail if the CPU driver doesn't support performance power profile
    if ! powerprofilesctl list | grep -q 'performance:'; then
        exec "$@"
    fi

    # Set performance governors, as long the game is launched
    exec "$INHIBIT" --why "CachyOS game-performance is running" "$PPCTL" launch \
            -p performance -r "Launched with CachyOS game-performance utility" -- "$@"
  '';
in {
  inherit scriptContent;
}
