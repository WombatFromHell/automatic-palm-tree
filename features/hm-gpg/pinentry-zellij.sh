#!/usr/bin/env bash
# pinentry-zellij.sh – zellij floating-pane pinentry wrapper

# -----------------------------------------------------------------------------
# Popup mode: runs inside the zellij floating pane
# -----------------------------------------------------------------------------
if [ -z "${PINENTRY_TMUX_PROGRAM:-}" ]; then
  while read -r p; do
    [[ "$p" != "$0" && -x "$p" ]] && {
      PINENTRY_TMUX_PROGRAM="$p"
      break
    }
  done < <(which -a pinentry)
fi

if [[ -n "${PINENTRY_TMUX_CALLER:-}" ]]; then
  # Wait briefly for zellij to finalize pane geometry
  sleep 0.1

  popup_tty="$(tty)"

  # Use the ACTUAL terminal size instead of assuming xterm defaults
  TTYTYPE="${TERM:-xterm-256color}"

  exec 0<"${PINENTRY_TMUX_STDIN}" 1>"${PINENTRY_TMUX_STDOUT}"

  unset ZELLIJ
  unset ZELLIJ_PANE_ID

  trap 'kill -USR1 "$PINENTRY_TMUX_CALLER" 2>/dev/null; exit 1' INT

  "${PINENTRY_TMUX_PROGRAM}" \
    --ttyname="$popup_tty" \
    --ttytype="$TTYTYPE" \
    --lc-ctype="${LC_CTYPE:-C}"
  rc=$?

  exit "$rc"
fi

# -----------------------------------------------------------------------------
# Main wrapper: runs in the original zellij pane
# -----------------------------------------------------------------------------
set -uo pipefail
pid_pinentry_tmux=$$
TIMEOUT="${PINENTRY_TMUX_TIMEOUT:-30}"

if [[ -z "${ZELLIJ:-}" ]] || ! zellij action query-tab-names &>/dev/null; then
  exec "$PINENTRY_TMUX_PROGRAM" "$@"
fi

fifodir=$(mktemp -d -t pinentry-zellij.XXXXXX)
to_popup="$fifodir/to_popup"
from_popup="$fifodir/from_popup"
mkfifo "$to_popup" "$from_popup"

cleanup() {
  [[ -n "${pid_watchdog:-}" ]] && kill -0 "$pid_watchdog" 2>/dev/null && kill "$pid_watchdog" 2>/dev/null || true
  [[ -n "${pid_in_sock:-}" ]] && kill -0 "$pid_in_sock" 2>/dev/null && kill "$pid_in_sock" 2>/dev/null || true
  rm -rf "$fifodir" 2>/dev/null || true
}

abort() {
  echo "ERR 83886179 Operation cancelled <Pinentry-Zellij>"
  exit 1
}

trap abort USR1
trap cleanup EXIT
trap 'exit 1' INT TERM

cat <"$from_popup" &
pid_in_sock=$!

(
  sleep "$TIMEOUT"
  kill -USR1 "$pid_pinentry_tmux" 2>/dev/null
) &
pid_watchdog=$!

# Launch floating pane — explicitly exclude ZELLIJ_PANE_ID from inherited env
(
  trap - EXIT INT USR1

  DESIRED_WIDTH=80
  DESIRED_HEIGHT=20

  envs=()
  while IFS='=' read -r key _; do
    # Skip ZELLIJ_PANE_ID to prevent the popup from inheriting the parent's pane ID
    [[ "$key" == "ZELLIJ_PANE_ID" ]] && continue
    envs+=("$key")
  done < <(env)

  # Build clean env array with values
  clean_env=()
  for key in "${envs[@]}"; do
    clean_env+=("${key}=${!key}")
  done

  zellij run \
    --floating \
    --close-on-exit \
    --width "$DESIRED_WIDTH" \
    --height "$DESIRED_HEIGHT" \
    --name "pinentry-zellij" \
    -- \
    env \
    "${clean_env[@]}" \
    PINENTRY_TMUX_CALLER="$pid_pinentry_tmux" \
    PINENTRY_TMUX_STDIN="$to_popup" \
    PINENTRY_TMUX_STDOUT="$from_popup" \
    PINENTRY_TMUX_PROGRAM="$PINENTRY_TMUX_PROGRAM" \
    TERM="${TERM:-xterm-256color}" \
    LC_CTYPE="${LC_CTYPE:-C}" \
    "$0" || true
) &
pid_popup=$!

exec 3>"$to_popup"
while IFS='' read -r line; do
  case "$line" in
  OPTION\ ttyname=*) printf "OK\n" ;;
  GETINFO\ flavor*) printf "D pinentry-zellij\nOK\n" ;;
  *) printf "%s\n" "$line" >&3 ;;
  esac
done

echo "BYE" >&3
exec 3>&-

wait "$pid_in_sock" 2>/dev/null || true
wait "$pid_popup" 2>/dev/null || true
