#!/usr/bin/env bash
# Nightly: tar the fossil record (daily checkpoints, latest, ledger, journal) into /var/backups/vesper; keep 14.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/var/backups/vesper
mkdir -p "$DEST"
tar -czf "$DEST/vesper-$(date -u +%Y%m%d).tar.gz" checkpoints/daily checkpoints/latest.json ledger journal 2>/dev/null || true
ls -1t "$DEST"/vesper-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
echo "backup ok: $(ls -1 "$DEST" | wc -l) archives"
