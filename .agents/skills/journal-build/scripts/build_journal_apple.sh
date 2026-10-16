#!/usr/bin/env bash
# One Apple build entry point; never installs, updates dependencies or clears caches.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$script_dir/journal_build.py" "$@"
