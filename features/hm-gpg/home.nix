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

    # 1. Check for Tmux or Zellij multiplexer hints via PINENTRY_USER_DATA
    if [ "$PINENTRY_USER_DATA" = "tmux" ] && command -v tmux >/dev/null 2>&1; then
      exec timeout ${popupTimeout} "${pinentryTmux}/bin/pinentry-tmux" "$@"
    fi

    if [ "$PINENTRY_USER_DATA" = "zellij" ] && command -v zellij >/dev/null 2>&1; then
      exec timeout ${popupTimeout} "${pinentryZellij}/bin/pinentry-zellij" "$@"
    fi

    # 2. Graphical PINEntry fallback (if X11 or Wayland is active)
    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
      if [ -x "${pkgs.pinentry-qt}/bin/pinentry-qt" ]; then
        exec "${pkgs.pinentry-qt}/bin/pinentry-qt" "$@"
      elif [ -x "${pkgs.pinentry-gnome3}/bin/pinentry-gnome3" ]; then
        exec "${pkgs.pinentry-gnome3}/bin/pinentry-gnome3" "$@"
      fi
    fi

    # 3. Local Terminal Curses fallback (for local lazygit/terminal use, outside SSH)
    # Checks that we have a valid TTY AND are not in an SSH session
    if [ -z "$SSH_CLIENT" ] && [ -z "$SSH_CONNECTION" ] && { [ -t 0 ] || [ -n "$GPG_TTY" ]; }; then
      exec "${pkgs.pinentry-curses}/bin/pinentry-curses" "$@"
    fi

    # 4. Ultimate fallback (SSH sessions or headless environments without TTY redrawing)
    exec "${pkgs.pinentry-tty}/bin/pinentry-tty" "$@"
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
