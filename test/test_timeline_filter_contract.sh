#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dune exec ./test/timeline_filter_contract_test.exe
