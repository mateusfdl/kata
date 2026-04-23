#!/usr/bin/env bash
set -euo pipefail

BINARY="${KATA_BIN:-./bin/kata}"
FIXTURES_DIR="${KATA_FIXTURES:-bench/fixtures}"

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine not found in PATH" >&2
  exit 1
fi

if [[ ! -x "${BINARY}" ]]; then
  echo "kata binary not found or not executable: ${BINARY}" >&2
  echo "run 'make release-native' (or 'make build') first" >&2
  exit 1
fi

if [[ ! -d "${FIXTURES_DIR}" ]]; then
  echo "fixtures directory not found: ${FIXTURES_DIR}" >&2
  exit 1
fi

shopt -s nullglob
FIXTURES=("${FIXTURES_DIR}"/*.ts)
if [[ ${#FIXTURES[@]} -eq 0 ]]; then
  echo "no *.ts fixtures found in ${FIXTURES_DIR}" >&2
  exit 1
fi

for fixture in "${FIXTURES[@]}"; do
  name="$(basename "${fixture}" .ts)"
  hyperfine \
    --warmup 30 \
    --min-runs 300 \
    --shell=none \
    --input "${fixture}" \
    --command-name "${name}" \
    -i \
    "${BINARY} --lang=ts"
done
