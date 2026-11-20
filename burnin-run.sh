# burnin-run — endless hardware burn-in cycle of the burn-in stick.
# Every phase records one JSON event in $BURNIN_STATE/events.jsonl; the
# tty1 dashboard (dashboard.py) renders them. Full tool output per
# phase lands in $BURNIN_STATE/logs/.
#
# The cycle mixes sustained load with load/idle transitions on purpose:
# faults that only appear with C-states and frequency changes under Linux
# never show up in memtest86+ at a fixed clock, and a load-only test
# would miss them too.
#
# BURNIN_SCALE divides every phase duration (a quick local run of the
# whole cycle: BURNIN_SCALE=60).

STATE=${BURNIN_STATE:-/run/burnin}
SCALE=${BURNIN_SCALE:-1}
# The resident RAM block lives on the root tmpfs, not in /run (which is
# capped at 25 % of RAM and also holds the logs).
BLOB=${BURNIN_BLOB:-/var/tmp/burnin-blob}
BLOB_MB=256
LOGS="$STATE/logs"
mkdir -p "$LOGS"
touch "$STATE/events.jsonl"

NPROC=$(nproc)
# Continue the cycle count after a service restart.
cycle=$(jq -s 'map(.cycle) | max // 0' "$STATE/events.jsonl")

now() { date +%s; }
secs() { echo $(( $1 / SCALE > 1 ? $1 / SCALE : 1 )); }
mem_avail_mb() { awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo; }

phase_begin() { # name duration-seconds (0 = unknown)
  jq -cn --argjson cycle "$cycle" --arg phase "$1" \
    --argjson started "$(now)" --argjson duration "$2" \
    '{cycle: $cycle, phase: $phase, started: $started, duration: $duration}' \
    > "$STATE/phase.json.tmp"
  mv "$STATE/phase.json.tmp" "$STATE/phase.json"
}

# record test result rc detail — result is pass | fail | warn
record() {
  jq -cn --argjson t "$(now)" --argjson cycle "$cycle" --arg test "$1" \
    --arg result "$2" --argjson rc "$3" --arg detail "$4" \
    '{t: $t, cycle: $cycle, test: $test, result: $result, rc: $rc, detail: $detail}' \
    >> "$STATE/events.jsonl"
  if [ "$2" != pass ]; then
    echo "cycle $cycle: $1 $2 (rc=$3): $4" >&2
  fi
}

# Map a stress-ng exit code to a result (stress-ng(1) EXIT STATUS):
# 2 stressor failed, 5 killed by signal, 6 unexpected exit, 7 corrupted
# counters = hardware suspects; 1/3/4 are harness/resource problems.
stressng_result() {
  case $1 in
    0) echo pass ;;
    2|5|6|7) echo fail ;;
    *) echo warn ;;
  esac
}

# Interesting lines of a log for the event detail (empty if none).
log_detail() {
  rg -i -e 'fail' -e 'error' -e 'miscompare' -e 'killed' "$1" \
    | rg -v -e 'failed: 0' -e 'please verify no corrected errors' \
    | tail -n 3 | cut -c1-200 || true
}

# ── Phases ──────────────────────────────────────────────────────────────

phase_stressapptest() {
  local d log rc=0 mb
  d=$(secs 900)
  log="$LOGS/c$cycle-stressapptest.log"
  phase_begin stressapptest "$d"
  mb=$(( $(mem_avail_mb) * 70 / 100 ))
  # -W: CPU-heavier copy; --cc_test: cache-coherency threads across cores;
  # pause_delay/pause_duration: periodic power spikes (load drops to idle
  # and back), i.e. exactly the transitions a marginal board fails under.
  stressapptest -s "$d" -M "$mb" -m "$NPROC" -W --cc_test \
    --pause_delay 120 --pause_duration 15 -l "$log" >/dev/null 2>&1 || rc=$?
  if rg -q 'Status: PASS' "$log" && [ "$rc" -eq 0 ]; then
    record stressapptest pass "$rc" ""
  elif rg -q 'Status: FAIL' "$log"; then
    record stressapptest fail "$rc" "$(log_detail "$log")"
  else
    record stressapptest warn "$rc" "no status line: $(tail -n 2 "$log" | cut -c1-200)"
  fi
}

phase_stressng() { # test-name duration stress-ng-args...
  local name=$1 d log rc=0
  d=$(secs "$2")
  shift 2
  log="$LOGS/c$cycle-$name.log"
  phase_begin "$name" "$d"
  stress-ng "$@" --verify --timeout "${d}s" --metrics-brief \
    --log-file "$log" >/dev/null 2>&1 || rc=$?
  record "$name" "$(stressng_result "$rc")" "$rc" "$(log_detail "$log")"
}

phase_memtester() {
  local d log rc=0 per i pids=() fails=0
  d=$(secs 1500)
  log="$LOGS/c$cycle-memtester.log"
  phase_begin memtester "$d"
  # One instance per core, half of the free memory in total, one loop.
  per=$(( $(mem_avail_mb) / 2 / NPROC ))
  : > "$log"
  for i in $(seq "$NPROC"); do
    timeout "$d" memtester "${per}M" 1 > "$log.$i" 2>&1 &
    pids+=("$!")
  done
  for i in "${!pids[@]}"; do
    rc=0
    wait "${pids[$i]}" || rc=$?
    cat "$log.$((i + 1))" >> "$log"
    rm -f "$log.$((i + 1))"
    # memtester exit bits: 0x02 address test, 0x04 other tests failed.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ $(( rc & 6 )) -ne 0 ]; then
      fails=$(( fails + 1 ))
    elif [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
      record memtester warn "$rc" "instance $((i + 1)) exited $rc (allocation?)"
    fi
  done
  if [ "$fails" -gt 0 ]; then
    record memtester fail 1 "$fails instance(s) failed: $(rg -m3 -i 'FAILURE' "$log" | cut -c1-200)"
  else
    record memtester pass 0 ""
  fi
}

phase_integrity() {
  local log rc=0 ref sum i bad=0
  log="$LOGS/c$cycle-integrity.log"
  phase_begin integrity 0

  # 1. Every store path re-read and hashed (page cache after the first
  #    cycle): catches program bytes that are fine on disk but wrong in RAM.
  nix-store --verify --check-contents > "$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && ! rg -q 'was modified' "$log"; then
    record store-verify pass 0 ""
  else
    record store-verify fail "$rc" "$(rg -m3 -e 'was modified' -e 'error' "$log" | cut -c1-200)"
  fi

  # 2. The same 256 MiB block stays in RAM for the whole run and is
  #    re-hashed every cycle: catches a flip in long-resident data.
  ref=$(cat "$STATE/blob.sha256")
  sum=$(sha256sum "$BLOB" | cut -d' ' -f1)
  if [ "$sum" = "$ref" ]; then
    record ram-blob pass 0 ""
  else
    record ram-blob fail 1 "blob hash changed: $sum (expected $ref)"
    # Count every flip once (memtest semantics): the changed content is
    # the new reference.
    echo "$sum" > "$STATE/blob.sha256"
  fi

  # 3. Compress/decompress round trip on every core in parallel, compared
  #    with the block's current hash (a flip in the block itself is
  #    already counted above).
  for i in $(seq "$NPROC"); do
    (zstd -q -c -T1 -6 "$BLOB" | zstd -q -dc | sha256sum | cut -d' ' -f1 \
      > "$STATE/zstd.$i") &
  done
  wait
  for i in $(seq "$NPROC"); do
    if [ "$(cat "$STATE/zstd.$i")" != "$sum" ]; then
      bad=$(( bad + 1 ))
    fi
    rm -f "$STATE/zstd.$i"
  done
  if [ "$bad" -eq 0 ]; then
    record zstd-roundtrip pass 0 ""
  else
    record zstd-roundtrip fail 1 "$bad of $NPROC round trips differ"
  fi
}

phase_burst() {
  local d end log rc worst=pass r
  d=$(secs 600)
  log="$LOGS/c$cycle-burst.log"
  phase_begin burst "$d"
  end=$(( $(now) + d ))
  : > "$log"
  # 3 s full load, 4 s idle: constant P-state and C-state transitions.
  while [ "$(now)" -lt "$end" ]; do
    rc=0
    stress-ng --cpu 0 --cpu-method all --verify --timeout 3s \
      --log-file "$log.tmp" >/dev/null 2>&1 || rc=$?
    r=$(stressng_result "$rc")
    if [ "$r" = fail ] || { [ "$r" = warn ] && [ "$worst" = pass ]; }; then
      worst=$r
      cat "$log.tmp" >> "$log"
    fi
    rm -f "$log.tmp"
    sleep 4
  done
  record burst "$worst" 0 "$(log_detail "$log")"
}

phase_idle() {
  local d
  d=$(secs 600)
  phase_begin idle "$d"
  # Deep C-states, like a server idling at night.
  sleep "$d"
  record idle pass 0 ""
}

# ── Main ────────────────────────────────────────────────────────────────

if [ ! -s "$STATE/blob.sha256" ] || [ ! -f "$BLOB" ]; then
  phase_begin prepare 0
  # Compressible, deterministic-enough content: the start of the store.
  # (tar dies of SIGPIPE once head has its bytes — expected.)
  tar -C / -cf - nix/store 2>/dev/null | head -c "${BLOB_MB}M" > "$BLOB.tmp" || true
  if [ "$(stat -c %s "$BLOB.tmp")" -ne $(( BLOB_MB * 1024 * 1024 )) ]; then
    echo "prepare: RAM block is $(stat -c %s "$BLOB.tmp") bytes, expected ${BLOB_MB} MiB" >&2
    exit 1
  fi
  mv "$BLOB.tmp" "$BLOB"
  sha256sum "$BLOB" | cut -d' ' -f1 > "$STATE/blob.sha256.tmp"
  mv "$STATE/blob.sha256.tmp" "$STATE/blob.sha256"
fi
if [ ! -s "$STATE/run.json" ]; then
  jq -cn --argjson start "$(now)" '{start: $start}' > "$STATE/run.json"
fi

while true; do
  cycle=$(( cycle + 1 ))
  phase_stressapptest
  phase_stressng cpu-icache 600 --cpu 0 --cpu-method all --icache "$NPROC"
  phase_stressng memory 600 --vm "$NPROC" --vm-bytes 60% --vm-method all
  phase_memtester
  phase_integrity
  phase_burst
  phase_idle
done
