{pkgs, ...}: let
  # fork of eth-p/pinentry-tmux: single self-contained bash script
  # Bridges gpg-agent's Assuan pipe to a tmux popup pane via a fifo pair,
  # so pinentry-curses doesn't share a screen buffer with whatever TUI
  # (lazygit) is running in the calling pane.
  pinentryTmux = pkgs.writeShellScriptBin "pinentry-tmux" (
    builtins.readFile ./pinentry-tmux.sh
  );

  # Same mechanism, ported to zellij's `run --floating --blocking` primitive
  # in place of tmux's `display-popup -E`. See inline comments for the two
  # zellij-specific gotchas: trap inheritance in the backgrounded subshell,
  # and the watchdog covering an intermittent hang observed in testing.
  pinentryZellij = pkgs.writeShellScriptBin "pinentry-zellij" (
    builtins.readFile ./pinentry-zellij.sh
  );

  candidates = [
    "${pkgs.pinentry-qt}/bin/pinentry-qt"
    "${pkgs.pinentry-gnome3}/bin/pinentry-gnome3"
    "${pkgs.pinentry-curses}/bin/pinentry-curses"
  ];

  # Outer timeout as a second safety net around the popup dispatchers,
  # independent of pinentry-zellij's own internal watchdog — belt and
  # braces, since a hung sign blocks git/lazygit indefinitely otherwise.
  popupTimeout = "30";

  pinentryWrapper = pkgs.writeShellScriptBin "pinentry-fallback" ''
    if ! "${pkgs.ncurses}/bin/infocmp" "$TERM" >/dev/null 2>&1; then
      export TERM=xterm-256color
    fi

    ttyname=""
    for arg in "$@"; do
      case "$arg" in
        --ttyname=*) ttyname="''${arg#--ttyname=}" ;;
      esac
    done
    : "''${ttyname:=$GPG_TTY}"

    export PINENTRY_TMUX_PROGRAM="${pkgs.pinentry-curses}/bin/pinentry-curses"

    # Walk process ancestry from whatever pid is attached to $ttyname,
    # looking for a tmux/zellij ancestor -- neither exposes a direct
    # "which multiplexer owns this tty" query, so ancestry is the reliable
    # signal (pane shells are direct children of the tmux server / zellij
    # binary in both cases).
    __owning_multiplexer() {
      tty_short="''${1#/dev/}"
      pid=$(ps -eo pid=,tty=,comm= 2>/dev/null | awk -v t="$tty_short" '$2==t{print $1; exit}')
      [ -n "$pid" ] || return 1
      while [ -n "$pid" ] && [ "$pid" != "1" ]; do
        comm=$(ps -o comm= -p "$pid" 2>/dev/null)
        case "$comm" in
          tmux*) echo tmux; return 0 ;;
          zellij*) echo zellij; return 0 ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      done
      return 1
    }

    if [ -n "$ttyname" ]; then
      owner=$(__owning_multiplexer "$ttyname")
      if [ "$owner" = tmux ] && command -v tmux >/dev/null 2>&1; then
        exec timeout ${popupTimeout} "${pinentryTmux}/bin/pinentry-tmux" "$@"
      fi
      if [ "$owner" = zellij ] && command -v zellij >/dev/null 2>&1; then
        exec timeout ${popupTimeout} "${pinentryZellij}/bin/pinentry-zellij" "$@"
      fi
    fi

    for p in ${pkgs.lib.concatStringsSep " " candidates}; do
      [ -x "$p" ] || continue
      case "$p" in
        *pinentry-qt|*pinentry-gnome3)
          { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; } || continue
          ;;
      esac
      exec "$p" "$@"
    done

    exec "${pkgs.pinentry-tty}/bin/pinentry-tty" "$@"
  '';
in {
  home.packages = [pinentryWrapper pinentryTmux pinentryZellij];
  programs.gpg.enable = true;
  services.gpg-agent = {
    enable = true;
    pinentry.package = pinentryWrapper;
    enableSshSupport = true;
    maxCacheTtl = 60480000;
    defaultCacheTtl = 60480000;
  };
}
