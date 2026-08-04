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

  # Outer timeout as a second safety net around the popup dispatchers,
  # independent of pinentry-zellij's own internal watchdog — belt and
  # braces, since a hung sign blocks git/lazygit indefinitely otherwise.
  popupTimeout = "30";

  pinentryWrapper = pkgs.writeShellScriptBin "pinentry-fallback" ''
    if ! "${pkgs.ncurses}/bin/infocmp" "$TERM" >/dev/null 2>&1; then
      export TERM=xterm-256color
    fi
    export PINENTRY_TMUX_PROGRAM="${pkgs.pinentry-curses}/bin/pinentry-curses"

    # 1. GUI askpass, whenever a display is actually reachable -- covers
    # local sessions regardless of tmux/zellij/SSH state, since a real
    # window always beats a terminal popup when one's available.
    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
      if [ -x "${pkgs.pinentry-qt}/bin/pinentry-qt" ]; then
        exec "${pkgs.pinentry-qt}/bin/pinentry-qt" "$@"
      elif [ -x "${pkgs.pinentry-gnome3}/bin/pinentry-gnome3" ]; then
        exec "${pkgs.pinentry-gnome3}/bin/pinentry-gnome3" "$@"
      fi
    fi

    # 2. tmux/zellij popup dispatchers -- only when there's no display to
    # fall back to (i.e. we're on a remote/headless SSH client) AND we're
    # actually inside a live multiplexer session, checked via the real
    # $TMUX/$ZELLIJ env vars rather than PINENTRY_USER_DATA.
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
      if [ -n "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
        exec timeout ${popupTimeout} "${pinentryTmux}/bin/pinentry-tmux" "$@"
      fi
      if [ -n "$ZELLIJ" ] && command -v zellij >/dev/null 2>&1; then
        exec timeout ${popupTimeout} "${pinentryZellij}/bin/pinentry-zellij" "$@"
      fi
    fi

    # 3. Local terminal curses fallback, outside SSH, when nothing above matched.
    if [ -z "$SSH_CLIENT" ] && [ -z "$SSH_CONNECTION" ] && { [ -t 0 ] || [ -n "$GPG_TTY" ]; }; then
      exec timeout ${popupTimeout} "${pkgs.pinentry-curses}/bin/pinentry-curses" "$@"
    fi

    # 4. Ultimate fallback: SSH/headless with no multiplexer, no display, no TTY.
    exec timeout ${popupTimeout} "${pkgs.pinentry-tty}/bin/pinentry-tty" "$@"
  '';
in {
  home.packages = [pinentryWrapper pinentryTmux pinentryZellij];
  programs.gpg.enable = true;
  services.gpg-agent = let
    defaultTtl = 60480000;
  in {
    enable = true;
    pinentry.package = pinentryWrapper;
    enableSshSupport = true;
    maxCacheTtl = defaultTtl;
    defaultCacheTtl = defaultTtl;
    maxCacheTtlSsh = defaultTtl;
    defaultCacheTtlSsh = defaultTtl;
  };
}
