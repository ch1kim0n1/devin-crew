#!/usr/bin/env bash
# Run the offline smoke test on Linux inside a container. No network needed, nothing is installed or pulled.
#   bash tests/linux-docker.sh [image]      default image: any local Debian/Ubuntu image that has bash, git, python3, pgrep
# The image needs bash, git, python3, procps (pgrep/pkill), tar. A missing `sqlite3` binary is covered by tests/linux/sqlite3.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
img=${1:-clockworklabs/spacetime:v2.14.1}
exec docker run --rm --pull=never --network=none -v "$here":/skill:ro --entrypoint bash "$img" -c '
  set -e; cp -R /skill /tmp/skill; cd /tmp/skill
  . /etc/os-release; echo "linux: $PRETTY_NAME, $(bash --version | head -1 | cut -c1-40)"
  export PATH="/tmp/skill/tests/linux:$PATH"
  git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
  bash tests/smoke.sh'
