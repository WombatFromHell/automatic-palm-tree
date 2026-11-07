#!/usr/bin/env bats
# tests/nix-eval.sh: the scope wrapper and its poller, with systemd mocked. These cost no scope and
# no eval, so they belong in the stub tier — but they floor the poller's subprocess churn (REVIEW
# finding 8), which is the largest non-test CPU cost in the gate: ~150 subprocesses per second per
# job at 3 `systemctl show` calls every 20ms, spent on a box that is already CPU-starved.
#
# The mock answers with a ramp: every poll reports 1MB more than the last, so the reported peak is
# exactly the number of polls. That makes the peak line and the call count the same measurement —
# a poll that reads the properties in the wrong order, or misses one, shows up as a wrong peak.
load helpers

setup() {
  harness_stub_dir
  # systemd-run: drop the unit properties and run the command the scope would run. The probe call
  # (`... true`) and the real scope call go through the same stub. Unquoted heredoc, like every
  # other stub here: the log path is baked in at write time, the rest stays unevaluated.
  stub systemd-run <<EOF
#!/usr/bin/env bash
printf 'systemd-run %s\n' "\$*" >>"$calls"
while [ \$# -gt 0 ]; do
  case "\$1" in
    --user | --scope | -q) shift ;;
    --unit=* | --expand-environment=*) shift ;;
    -p) shift 2 ;;
    *) break ;;
  esac
done
exec "\$@"
EOF
  # systemctl: one line per requested property, in the order asked, ramping 1MB per call.
  stub systemctl <<EOF
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >>"$calls"
step=\$(cat "$stubs/step")
# The ramp advances once per memory report, not per call: a call that only asks for the swap
# peak must not inflate the peak line, or the peak would read one MB higher than the poll count.
case " \$* " in
*MemoryCurrent* | *MemoryPeak*)
step=\$((step + 1))
printf '%s\n' "\$step" >"$stubs/step"
;;
esac
for arg in "\$@"; do
  case "\$arg" in
    MemoryCurrent) printf '%s\n' \$((step * 1048576)) ;;
    MemoryPeak)    printf '%s\n' \$((step * 1048576)) ;;
    MemorySwapPeak) printf '4194304\n' ;;
  esac
done
EOF
  printf '0\n' >"$stubs/step"
  PATH="$stubs:$PATH"
}

polls() { grep -c '^systemctl ' "$calls"; }

@test "the poller asks systemd once per sample, not once per property" {
  run tests/nix-eval.sh 200 -- sleep 0.6
  [ "$status" = 0 ]
  # ~0.6s sampled at 0.1s is at most a handful of polls; three calls per 20ms is ~90.
  [ "$(polls)" -le 12 ]
}

@test "the reported peak is the highest value the scope reached" {
  run tests/nix-eval.sh 200 -- sleep 0.6
  [ "$status" = 0 ]
  assert_out "peak=$(polls)MB"
}

@test "swap peak is reported next to the memory peak" {
  run tests/nix-eval.sh 200 -- sleep 0.2
  [ "$status" = 0 ]
  assert_out "swap=4MB"
}

@test "the cap reaches the unit as MemoryMax" {
  run tests/nix-eval.sh 200 -- true
  [ "$status" = 0 ]
  assert_call "MemoryMax=200M"
}

@test "a scope that cannot start runs unscoped and says peak=n/a" {
  stub systemd-run <<EOF
#!/usr/bin/env bash
printf 'systemd-run %s\n' "\$*" >>"$calls"
exit 1
EOF
  run tests/nix-eval.sh 200 -- sh -c 'printf hello'
  [ "$status" = 0 ]
  assert_out "hello"
  assert_out "peak=n/a"
  # The command ran exactly once: the failed probe must not become a second run.
  assert_calls '^systemd-run .* true$' 1
}

@test "output without a trailing newline still gets its own peak line" {
  run tests/nix-eval.sh 200 -- sh -c 'printf abc'
  [ "$status" = 0 ]
  assert_out_count "peak=" 1
  assert_out "abc"
}
