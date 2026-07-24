#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
DEV_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ROOT="$(cd -- "$DEV_ROOT/.." && pwd -P)"

for script_file in "$ROOT"/scripts/*.sh "$ROOT"/scripts/clowder "$ROOT"/scripts/clowder-orchestrator "$DEV_ROOT"/scripts/*.sh; do
  bash -n "$script_file"
done

bash -n "$ROOT/templates/pre-push-hook"

for json_file in "$ROOT"/schemas/*.json "$ROOT"/skill-lock.json "$DEV_ROOT"/toolchain.lock.json "$ROOT"/package-lock.json "$ROOT"/package.json; do
  jq empty "$json_file" >/dev/null
done

for yaml_file in "$ROOT"/templates/*.yaml; do
  ruby -r yaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$yaml_file" >/dev/null
done

if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
  for toml_file in "$ROOT"/.codex/config.toml "$ROOT"/.codex/agents/*.toml; do
    python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$toml_file"
  done
elif command -v codex >/dev/null 2>&1; then
  (cd -- "$ROOT" && codex --strict-config doctor --json >/dev/null)
else
  printf '%s\n' 'Python 3.11+ and Codex are unavailable, skipped TOML syntax gate' >&2
fi

for markdown_file in "$ROOT"/*.md "$DEV_ROOT"/*.md "$ROOT"/templates/*.md "$ROOT"/skills/*/SKILL.md; do
  [[ -s "$markdown_file" ]] || { printf 'empty Markdown file: %s\n' "$markdown_file" >&2; exit 1; }
done

for command_name in node shellcheck bats; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'required validation command is unavailable: %s\n' "$command_name" >&2; exit 1; }
done

expected_shellcheck="$(jq -r '.shellcheck' "$DEV_ROOT/toolchain.lock.json")"
actual_shellcheck="$(shellcheck --version | awk '$1 == "version:" { print $2 }')"
[[ "$actual_shellcheck" == "$expected_shellcheck" ]] || { printf 'ShellCheck version mismatch: expected %s, found %s\n' "$expected_shellcheck" "$actual_shellcheck" >&2; exit 1; }
expected_bats="$(jq -r '.bats' "$DEV_ROOT/toolchain.lock.json")"
actual_bats="$(bats --version | awk '{ print $2 }')"
[[ "$actual_bats" == "$expected_bats" ]] || { printf 'Bats version mismatch: expected %s, found %s\n' "$expected_bats" "$actual_bats" >&2; exit 1; }

shellcheck -x -P "$ROOT/scripts:$DEV_ROOT/scripts" "$ROOT"/scripts/*.sh "$ROOT"/scripts/clowder "$ROOT"/scripts/clowder-orchestrator "$DEV_ROOT"/scripts/*.sh
bats "$DEV_ROOT"/tests/*.bats

"$DEV_ROOT/tests/run.sh"
printf '%s\n' 'Clowder validation passed.'
