#!/usr/bin/env bash
# Run a heavy command (full build, whole test suite, browser run) when a slot is free, so lanes do not starve each other into
# timeouts that look like code failures. Crew-wide: the slots live in the project's .devin-crew/heavy/.
#   bash crew-heavy.sh <project> <command> [args...]       runs in the current folder, exit code is the command's
# env: CREW_HEAVY_SLOTS (default cores/4, at least 1) | CREW_HEAVY_WAIT=1800 s, then exit 75 without running it.
# A nested call runs at once (its slot is already held). A slot left by a dead process is taken over.
set -u
[ $# -ge 2 ] || { sed -n 2,6p "$0" >&2; exit 2; }
proj=$(cd "$1" && pwd -P) || exit 2; shift
[ "${CREW_HEAVY_HELD:-0}" = 1 ] && exec "$@"
. "$(cd "$(dirname "$0")" && pwd)/crew-lib.sh"
heavy_acquire "$proj/.devin-crew" || { echo "crew-heavy: no free slot after ${CREW_HEAVY_WAIT:-1800}s, not run: $*" >&2; exit 75; }
trap 'heavy_release' EXIT; trap 'exit 130' INT TERM
CREW_HEAVY_HELD=1 "$@"
