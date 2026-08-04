#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Popup mode: runs INSIDE the tmux popup
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
	trap 'kill -USR1 "$PINENTRY_TMUX_CALLER" 2>/dev/null; exit 1' INT

	MYTTY="$(tty)"
	TTYTYPE="${TERM:-xterm-256color}"
	infocmp "$TTYTYPE" &>/dev/null || TTYTYPE="xterm-256color"

	# Redirect to the FIFOs the parent prepared (already swapped)
	exec 0<"${PINENTRY_TMUX_STDIN}" 1>"${PINENTRY_TMUX_STDOUT}"

	"${PINENTRY_TMUX_PROGRAM}" \
		--ttyname="$MYTTY" \
		--ttytype="$TTYTYPE" \
		--lc-ctype="${LC_CTYPE:-C}"
	exit $?
fi

# -----------------------------------------------------------------------------
# Main wrapper: runs in the original pane
# -----------------------------------------------------------------------------
set -uo pipefail
pid_pinentry_tmux=$$
TIMEOUT="${PINENTRY_TMUX_TIMEOUT:-30}"

if ! tmux display-message -p "#{client_name}" &>/dev/null; then
	exec "$PINENTRY_TMUX_PROGRAM" "$@"
fi

# Create FIFOs for two-way communication
fifodir=$(mktemp -d -t pinentry-tmux.XXXXXX)
to_popup="$fifodir/to_popup"     # parent writes protocol here, popup reads from here
from_popup="$fifodir/from_popup" # popup writes responses here, parent reads from here
mkfifo "$to_popup" "$from_popup"

cleanup() {
	# Cancel timeout (if still running)
	if [[ -n "${pid_timeout:-}" ]] && kill -0 "$pid_timeout" 2>/dev/null; then
		kill "$pid_timeout" 2>/dev/null || true
	fi
	# Close popup if still alive
	if [[ -n "${pid_popup:-}" ]] && kill -0 "$pid_popup" 2>/dev/null; then
		tmux display-popup -C 2>/dev/null || true
		kill "$pid_popup" 2>/dev/null || true
	fi
	# Clean up background cat
	if [[ -n "${pid_cat:-}" ]] && kill -0 "$pid_cat" 2>/dev/null; then
		kill "$pid_cat" 2>/dev/null || true
	fi
	rm -rf "$fifodir" 2>/dev/null || true
}

abort() {
	echo "ERR 83886179 Operation cancelled <Pinentry-Tmux>"
	exit 1
}

trap abort USR1
trap cleanup EXIT
trap 'exit 1' INT TERM

# Start reading responses from the popup (prints them to stdout for gpg-agent)
cat <"$from_popup" &
pid_cat=$!

# Calculate popup dimensions
DESIRED_WIDTH=78
DESIRED_HEIGHT=18
read -r ACTUAL_WIDTH ACTUAL_HEIGHT < <(tmux display-message -p '#{client_width} #{client_height}')
[[ "$ACTUAL_WIDTH" -lt "$DESIRED_WIDTH" ]] && DESIRED_WIDTH="$ACTUAL_WIDTH"
[[ "$ACTUAL_HEIGHT" -lt "$DESIRED_HEIGHT" ]] && DESIRED_HEIGHT="$ACTUAL_HEIGHT"

# Launch the popup
tmux display-popup -E \
	-d "$(pwd)" \
	-e "PINENTRY_TMUX_CALLER=$pid_pinentry_tmux" \
	-e "PINENTRY_TMUX_PROGRAM=${PINENTRY_TMUX_PROGRAM:-}" \
	-e "PINENTRY_TMUX_STDIN=$to_popup" \
	-e "PINENTRY_TMUX_STDOUT=$from_popup" \
	-e "TERM=${TERM:-xterm-256color}" \
	-e "LC_CTYPE=${LC_CTYPE:-C}" \
	-T "[ pinentry-tmux ]" \
	-B \
	-w "$DESIRED_WIDTH" \
	-h "$DESIRED_HEIGHT" \
	"$0" &

pid_popup=$!

# Timeout safety net: force-close the popup after $TIMEOUT seconds
(
	sleep "$TIMEOUT"
	if kill -0 "$pid_popup" 2>/dev/null; then
		tmux display-popup -C 2>/dev/null || true
		kill "$pid_popup" 2>/dev/null || true
	fi
) &
pid_timeout=$!

# Forward protocol lines from gpg-agent to the popup (fd 3)
exec 3>"$to_popup"
while IFS='' read -r line; do
	case "$line" in
	OPTION\ ttyname=*)
		printf "OK\n"
		;;
	GETINFO\ flavor*)
		printf "D pinentry-tmux\nOK\n"
		;;
	*)
		printf "%s\n" "$line" >&3
		;;
	esac
done
# gpg-agent closed stdin – send BYE to close the pinentry cleanly
echo "BYE" >&3
exec 3>&- # close write end → pinentry sees EOF after BYE

# Wait for the popup to finish (pinentry exits → popup closes)
wait "$pid_cat" 2>/dev/null || true
wait "$pid_popup" 2>/dev/null || true

# Normal exit – cleanup cancels the timeout and tidies up
