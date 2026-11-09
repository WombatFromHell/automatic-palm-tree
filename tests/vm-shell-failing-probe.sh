#!/usr/bin/env bash
# Console probe that fails on purpose: it is the regression test for the run ending at once rather
# than idling to the boot timeout. It never reaches SHELL DONE, so only SHELL FAIL can end the run.
set -u
[ -e /repo/definitely-not-here ] || {
  echo "SHELL FAIL: probe reached its failing check"
  exit 1
}
echo "SHELL DONE"
poweroff
