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

    # 1. GUI askpass, only when a display is reachable *from this session*.
    # gpg hands the agent its own DISPLAY, so an empty $DISPLAY here means the
    # caller cannot see the desktop -- the case that hangs git/lazygit, because
    # the window opens on the host desktop while an SSH client waits forever.
    # A remote SSH session can only use a forwarded display (localhost:N).
    display_ok=0
    if [ -n "$DISPLAY" ]; then
      case "$DISPLAY" in
        localhost:*) display_ok=1 ;;
        *) if [ -z "$SSH_CLIENT" ] && [ -z "$SSH_CONNECTION" ]; then display_ok=1; fi ;;
      esac
    fi
    if [ "$display_ok" = 1 ]; then
      if [ -x "${pkgs.pinentry-qt}/bin/pinentry-qt" ]; then
        exec "${pkgs.pinentry-qt}/bin/pinentry-qt" "$@"
      elif [ -x "${pkgs.pinentry-gnome3}/bin/pinentry-gnome3" ]; then
        exec "${pkgs.pinentry-gnome3}/bin/pinentry-gnome3" "$@"
      fi
    fi

    # 2. tmux/zellij popup dispatchers -- whenever no display is usable from this
    # session (remote SSH pane, or a headless local one), checked via the real
    # $TMUX/$ZELLIJ env vars rather than PINENTRY_USER_DATA.
    if [ "$display_ok" = 0 ]; then
      # gpg-agent may be a systemd/desktop service whose environment carries no
      # $TMUX, so a prompt started from a tmux pane never sees it. Ask tmux itself
      # whether a client is attached; pinentry-tmux still falls back to plain
      # pinentry when there is no client to draw a popup in.
      if { [ -n "$TMUX" ] || tmux display-message -p '#{client_name}' >/dev/null 2>&1; } && command -v tmux >/dev/null 2>&1; then
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
