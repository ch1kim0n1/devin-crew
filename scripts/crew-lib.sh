#!/usr/bin/env bash
# Shared helpers, sourced by other crew scripts (never run by itself): bounded commands, the machine's size and load, the crew-wide
# gate for heavy commands, and the shared build cache. Test or calibrate with CREW_CORES, CREW_RAM_GB, CREW_SATURATED_FACTOR=1.5.

# ponytail: no coreutils `timeout` on macOS, so a background sleeper does the killing
run_limited() { # secs cmd outfile [dir] -> exit code (124 = timed out)
  local p w rc
  rm -f "${3:?}.to"
  (cd "${4:-.}" && exec bash -c "$2") </dev/null >"$3" 2>&1 & p=$!
  ( sleep "$1"; kill -0 "$p" 2>/dev/null || exit 0; : > "$3.to"; pkill -TERM -P "$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; sleep 2
    pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  disown "$w" 2>/dev/null
  wait "$p"; rc=$?
  pkill -P "$w" 2>/dev/null; kill "$w" 2>/dev/null
  if [ -e "$3.to" ]; then rc=124; rm -f "${3:?}.to"; fi
  return "$rc"
}

machine_cores() { echo "${CREW_CORES:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"; }
machine_ram_gb() {
  [ -n "${CREW_RAM_GB:-}" ] && { echo "$CREW_RAM_GB"; return; }
  if [ -r /proc/meminfo ]; then awk '/^MemTotal:/{printf "%d\n", $2 / 1048576 + 0.5}' /proc/meminfo
  else sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d\n", $1 / 1073741824 + 0.5}'; fi
}
machine_load() { LC_ALL=C uptime 2>/dev/null | sed -n 's/.*load averages\{0,1\}: *\([0-9.]*\).*/\1/p'; }   # 1-minute average
machine_saturated() { # more runnable work than the cores can carry: timeouts in this window say nothing about the code
  awk -v l="$(machine_load)" -v c="$(machine_cores)" -v f="${CREW_SATURATED_FACTOR:-1.5}" 'BEGIN { exit !(l + 0 > c * f) }'
}
build_lanes_hint() { # lanes this machine can carry when every lane builds and tests on its own: about 3 cores and 5 GB each, 1 to 5
  awk -v c="$(machine_cores)" -v r="$(machine_ram_gb)" 'BEGIN { k = int(c / 3); m = int(r / 5); if (r > 0 && m < k) k = m; if (k < 1) k = 1; if (k > 5) k = 5; print k }'
}

# The gate: one symlink per slot, holding the owner's pid (creating a symlink is atomic; macOS has no flock binary).
heavy_slots() { local n=${CREW_HEAVY_SLOTS:-$(( $(machine_cores) / 4 ))}; [ "$n" -ge 1 ] || n=1; echo "$n"; }
heavy_reclaim() { # slot: remove it if its owner is dead; only one reclaimer at a time, so a new owner's slot is never removed
  local lock="${1:?}.reclaim" p
  if mkdir "$lock" 2>/dev/null; then
    p=$(readlink "$1" 2>/dev/null); [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && rm -f "${1:?}"
    rmdir "$lock"
  else find "$lock" -maxdepth 0 -mmin +1 -exec rmdir {} \; 2>/dev/null; fi
}
heavy_acquire() { # <.devin-crew dir> [max wait secs] -> sets HEAVY_SLOT; 75 = no slot in time. waiting-<pid> tells the watchdog why we idle.
  local d="${1:?}/heavy" max=${2:-${CREW_HEAVY_WAIT:-1800}} n i s p t0
  mkdir -p "$d"; n=$(heavy_slots); t0=$(date +%s); HEAVY_SLOT=""
  : > "$d/waiting-$$"
  while :; do
    i=1
    while [ "$i" -le "$n" ]; do
      s="$d/slot-$i"
      if ln -s "$$" "$s" 2>/dev/null; then HEAVY_SLOT=$s; rm -f "${d:?}/waiting-$$"; return 0; fi
      p=$(readlink "$s" 2>/dev/null); [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && heavy_reclaim "$s"
      i=$((i + 1))
    done
    [ $(( $(date +%s) - t0 )) -ge "$max" ] && { rm -f "${d:?}/waiting-$$"; return 75; }
    sleep 1
  done
}
heavy_release() { [ -n "${HEAVY_SLOT:-}" ] && rm -f "${HEAVY_SLOT:?}"; HEAVY_SLOT=""; }

# Worktrees otherwise compile the same crates once per lane. sccache is safe to share between concurrent builds (a shared
# CARGO_TARGET_DIR is not: lock contention, and lanes running each other's binaries). It cannot cache incremental builds.
build_cache_env() { # <dir>: sets CREW_CACHE_ON=1 when it turned the cache on
  [ "${CREW_BUILD_CACHE:-1}" != 0 ] && [ -z "${RUSTC_WRAPPER:-}" ] && [ -f "${1:-.}/Cargo.toml" ] && command -v sccache >/dev/null 2>&1 || return 0
  export RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0
  # shellcheck disable=SC2034  # read by the script that sourced this file
  CREW_CACHE_ON=1
}
