#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# If called from within the popup, run the real pinentry program and
# forward its input and output to the caller pinentry-zellij script.
# -----------------------------------------------------------------------------

# If a pinentry program has not already been specified via the
# PINENTRY_TMUX_PROGRAM environment variable, look within the path for an
# executable named "pinentry".
if [ -z "${PINENTRY_TMUX_PROGRAM:-}" ]; then
	while read -r pinentry_program; do
		if [[ "$pinentry_program" = "$0" || ! -x "$pinentry_program" ]]; then
			continue
		fi
		PINENTRY_TMUX_PROGRAM="$pinentry_program"
		break
	done < <(which -a pinentry)
fi

# If PINENTRY_TMUX_CALLER is set, we're running inside the zellij floating
# pane. Run the real pinentry here and forward its output back to the
# original pinentry-zellij process via the fifo pair.
if [[ -n "${PINENTRY_TMUX_CALLER:-}" ]]; then
	popup_tty="$(tty)"

	# Redirect STDIN and STDOUT.
	exec 1>"${PINENTRY_TMUX_STDOUT}" 0<"${PINENTRY_TMUX_STDIN}"

	unset PINENTRY_TMUX_STDIN
	unset PINENTRY_TMUX_STDOUT
	unset ZELLIJ

	# Trap SIGINT to tell the original pinentry-zellij to cancel.
	trap 'rkill "$PINENTRY_TMUX_CALLER"; kill -USR1 "$PINENTRY_TMUX_CALLER"' INT

	# Call the real pinentry.
	# Force the TTY type to xterm for compatibility.
	exec "${PINENTRY_TMUX_PROGRAM}" \
		--ttyname="${popup_tty}" \
		--ttytype="xterm" \
		--lc-ctype="${LC_CTYPE:-c}"
fi

# -----------------------------------------------------------------------------
# pinentry-zellij
# -----------------------------------------------------------------------------

set -euo pipefail

pid_pinentry_tmux=$$

# If we're not running inside zellij, call the original pinentry directly.
if [[ -z "${ZELLIJ:-}" ]]; then
	exec "$PINENTRY_TMUX_PROGRAM" "$@"
fi

# Make a pair of FIFOs to communicate with the popup.
fifodir=$(mktemp -d)
PINENTRY_TMUX_STDOUT="$fifodir/r2t.sock"; mkfifo "$PINENTRY_TMUX_STDOUT"
PINENTRY_TMUX_STDIN="$fifodir/t2r.sock"; mkfifo "$PINENTRY_TMUX_STDIN"

# Function that kills all children of a process, except the process itself.
# Works with both BSD and GNU coreutils.
rkill() {
	{
		if ps --version &>/dev/null; then
			ps -o pid --ppid="$1" # GNU ps
		else
			ps -o pid -g "$1" # BSD ps
		fi
	} \
		| sed $'1d; s/[ \t]//g' \
		| grep -Fv "$1" \
		| xargs kill -INT \
		|| true
}

# Traps and cleanup.
cleanup() {
	if [ -n "${pid_watchdog:-}" ] && kill -0 "$pid_watchdog" &>/dev/null; then kill "$pid_watchdog" 2>/dev/null; fi
	if [ -e "$PINENTRY_TMUX_STDOUT" ]; then rm "$PINENTRY_TMUX_STDOUT"; fi
	if [ -e "$PINENTRY_TMUX_STDIN" ]; then rm "$PINENTRY_TMUX_STDIN"; fi
	if [ -d "$fifodir" ]; then rmdir "$fifodir"; fi
	if [ -n "${pid_in_sock:-}" ] && kill -0 "$pid_in_sock" &>/dev/null; then kill -INT "$pid_in_sock"; fi
	echo "BYE"
}

abort() {
	echo "ERR 83886179 Operation cancelled <Pinentry-Zellij>"
	rkill "$pid_pinentry_tmux" 2>/dev/null
	exit 1
}

trap abort USR1
trap cleanup EXIT INT

# Watchdog: we observed an intermittent hang in testing where the outer
# process can sit forever on the final `wait` calls even after the popup
# and relay have both finished doing useful work. A stuck sign blocks the
# caller (git/lazygit) indefinitely, which is worse than a clean failure,
# so self-terminate after PINENTRY_TMUX_TIMEOUT seconds rather than trust
# `wait` to always return.
: "${PINENTRY_TMUX_TIMEOUT:=30}"
(
	sleep "$PINENTRY_TMUX_TIMEOUT"
	kill -USR1 "$pid_pinentry_tmux" 2>/dev/null
) &
pid_watchdog=$!

# Read STDIN from the socket to pinentry-zellij STDOUT.
cat <"$PINENTRY_TMUX_STDIN" &
pid_in_sock=$!

# Create the popup.
#
# NOTE: this whole block runs in a backgrounded subshell. Backgrounded
# subshells INHERIT the parent's traps — without stripping them here,
# any failure inside this subshell (e.g. an unset var, a bad flag) fires
# the outer script's own `cleanup`/`abort` traps prematurely, deleting the
# fifos out from under the foreground process that still needs them.
(
	trap - EXIT INT USR1

	# Determine the ideal size for the floating pane, clamped to the
	# actual zellij client's dimensions if smaller than desired.
	DESIRED_WIDTH=78
	DESIRED_HEIGHT=18

	zellij run \
		--floating \
		--close-on-exit \
		--blocking \
		--width "$DESIRED_WIDTH" \
		--height "$DESIRED_HEIGHT" \
		--name "pinentry-zellij" \
		-- env \
			PINENTRY_TMUX_CALLER="$pid_pinentry_tmux" \
			PINENTRY_TMUX_STDIN="$PINENTRY_TMUX_STDOUT" \
			PINENTRY_TMUX_STDOUT="$PINENTRY_TMUX_STDIN" \
			PINENTRY_TMUX_PROGRAM="$PINENTRY_TMUX_PROGRAM" \
			"$0" \
		|| true
) &
pid_popup=$!

# Write STDOUT from pinentry-zellij to the socket STDIN.
# A couple options will need to be intercepted for this to work properly,
# since the popup pane — not this process — now owns the real tty that
# gpg-agent's Assuan negotiation expects to be talking about.
exec 3>"$PINENTRY_TMUX_STDOUT"
while IFS='' read -r line; do
	case "$line" in
		"OPTION ttyname="*) printf "OK\n"; continue ;;
		"GETINFO flavor"*) printf "D pinentry-zellij\nOK\n"; continue ;;
		*) printf "%s\n" "$line" 1>&3 ;;
	esac
done

# Wait for the real pinentry (via the fifo relay) and the popup pane to finish.
wait "$pid_in_sock"
wait "$pid_popup"
