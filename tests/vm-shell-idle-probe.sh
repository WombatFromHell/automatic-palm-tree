#!/usr/bin/env bash
# Keep the guest console alive so the host can push a closure into it over ssh and measure what that
# costs. Nothing here asserts anything; it exists to make the push mechanism measurable.
sleep "${IDLE_SECONDS:-200}"
echo "SHELL DONE"
poweroff
