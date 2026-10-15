#!/usr/bin/env bash
# One Apple build entry point; never installs, updates dependencies or clears caches.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 "$repo_root/tool/journal_build.py" "$@"
