#!/usr/bin/env bash
# KERNEL — frozen. Runs before every server start (systemd ExecStartPre) and before every overseer cycle.
# 1) Verifies the kernel hash manifest; restores kernel/ from the last-known-good tag if touched.
# 2) After 3 consecutive boots that never reached "healthy" (10 minutes up), restores all code from last-known-good.
set -u
cd "$(dirname "$0")/.."
CODE_PATHS="kernel world viewer overseers ops project.godot Makefile export_presets.cfg"
SHA="$(command -v sha256sum || echo 'shasum -a 256')"

if ! $SHA -c --quiet kernel/KERNEL.sha256 >/dev/null 2>&1; then
  echo "guard: kernel hash mismatch — restoring kernel/ from last-known-good" >&2
  git checkout last-known-good -- kernel/ || exit 4
  $SHA -c --quiet kernel/KERNEL.sha256 || exit 4
fi

mkdir -p state
n=$(cat state/boot_failures 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0;; esac
if [ "$n" -ge 3 ]; then
  echo "guard: $n consecutive unhealthy boots — restoring code from last-known-good" >&2
  git checkout last-known-good -- $CODE_PATHS || true
  echo "$(date -u +%FT%TZ) restored code from last-known-good after $n unhealthy boots" >> state/guard.log
  n=0
fi
echo $((n + 1)) > state/boot_failures
exit 0
