#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

file=""
json=false

usage() {
  printf '%s\n' 'Usage: check-handoff.sh --file PATH [--json]'
}

while (($# > 0)); do
  case "$1" in
    --file) file=${2:?missing value for --file}; shift 2 ;;
    --json) json=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$file" ]] || { usage >&2; exit 2; }
[[ -f "$file" ]] || die "handoff file does not exist: $file"
validate_json "$file" || die "handoff is not valid JSON: $file"

errors=()
while IFS= read -r schema_error; do
  [[ -n "$schema_error" ]] && errors+=("handoff schema: $schema_error")
done < <(schema_validation_errors "$(clowder_root)/schemas/handoff.schema.json" "$file")

for key in status sources outputs evidence decisions assumptions risks questions next_gate; do
  jq -e --arg key "$key" 'has($key)' "$file" >/dev/null || errors+=("missing required key: $key")
done

jq -e '.status | IN("completed", "clarification-required", "blocked", "failed")' "$file" >/dev/null || errors+=("invalid status")
for key in sources outputs evidence decisions assumptions risks questions; do
  jq -e --arg key "$key" '.[$key] | type == "array" and all(.[]; type == "string")' "$file" >/dev/null || errors+=("$key must be an array of strings")
done
jq -e '.next_gate | type == "string" and length > 0' "$file" >/dev/null || errors+=("next_gate must be a non-empty string")

if [[ "$json" == true ]]; then
  jq -n --arg file "$file" --argjson errors "$(printf '%s\n' "${errors[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '{ok: ($errors|length == 0), file: $file, errors: $errors}'
else
  for item in "${errors[@]:-}"; do [[ -n "$item" ]] && printf 'clowder: error: %s\n' "$item" >&2; done
  if ((${#errors[@]} == 0)); then
    info "handoff is valid: $file"
  fi
fi

((${#errors[@]} == 0))
