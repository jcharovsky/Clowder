#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

repo_path=""
description=""
deterministic=false
risk="R1"
ambiguity="low"
scope="local"
failed_attempts=0
exception=false
json=false

usage() {
  cat <<'EOF'
Usage: route-task.sh [--repo PATH] --description TEXT [--deterministic] [--risk R1|R2|R3] [--ambiguity low|high] [--scope local|cross-module] [--failed-attempts N] [--exception] [--json]

Apply the Clowder task-routing heuristic without invoking a model.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo) repo_path=${2:?missing value for --repo}; shift 2 ;;
    --description) description=${2:?missing value for --description}; shift 2 ;;
    --deterministic) deterministic=true; shift ;;
    --risk) risk=${2:?missing value for --risk}; shift 2 ;;
    --ambiguity) ambiguity=${2:?missing value for --ambiguity}; shift 2 ;;
    --scope) scope=${2:?missing value for --scope}; shift 2 ;;
    --failed-attempts) failed_attempts=${2:?missing value for --failed-attempts}; shift 2 ;;
    --exception) exception=true; shift ;;
    --json) json=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$description" ]] || die "--description is required"
[[ "$risk" =~ ^R[123]$ ]] || die "invalid risk: $risk"
[[ "$ambiguity" =~ ^(low|high)$ ]] || die "invalid ambiguity: $ambiguity"
[[ "$scope" =~ ^(local|cross-module)$ ]] || die "invalid scope: $scope"
[[ "$failed_attempts" =~ ^[0-9]+$ ]] || die "invalid failed-attempts value: $failed_attempts"
description_lower="$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')"

models_luna="gpt-5.6-luna"
models_terra="gpt-5.6-terra"
models_sol="gpt-5.6-sol"
models_astra=""
if [[ -n "$repo_path" ]]; then
  repo_path="$(resolve_repo "$repo_path")"
  config="$(repo_config "$repo_path")"
  models_luna="$(yaml_scalar "$config" models.luna 2>/dev/null || printf '%s' "$models_luna")"
  models_terra="$(yaml_scalar "$config" models.terra 2>/dev/null || printf '%s' "$models_terra")"
  models_sol="$(yaml_scalar "$config" models.sol 2>/dev/null || printf '%s' "$models_sol")"
  models_astra="$(yaml_scalar "$config" models.astra 2>/dev/null || printf '%s' "$models_astra")"
fi

route="terra"
model="$models_terra"
reasoning_effort="medium"
reason="routine multi-step task"

if [[ "$deterministic" == true ]]; then
  route="script"
  model=""
  reasoning_effort=""
  reason="objective result can be produced and checked without semantic judgment"
elif [[ "$exception" == true ]]; then
  [[ -n "$models_astra" ]] || die "Astra route requested but models.astra is not configured"
  route="astra"
  model="$models_astra"
  reasoning_effort="xhigh"
  reason="human-approved exceptional quality-ceiling analysis"
elif [[ "$risk" == R3 || "$ambiguity" == high || "$scope" == cross-module || "$failed_attempts" -ge 2 || "$description_lower" =~ (architect|security|privacy|migration|review|incident|recovery) ]]; then
  route="sol"
  model="$models_sol"
  reasoning_effort="high"
  reason="ambiguous, consequential, cross-module, or repeatedly failing task"
elif [[ "$description_lower" =~ (mechanical|format|link|rename|summary|boilerplate|routine|jira) ]]; then
  route="luna"
  model="$models_luna"
  reasoning_effort="low"
  reason="narrow, local, reversible, and cheaply verified task"
fi

if [[ "$json" == true ]]; then
  jq -n --arg route "$route" --arg model "$model" --arg effort "$reasoning_effort" --arg reason "$reason" --arg description "$description" '{route: $route, model: $model, reasoning_effort: $effort, reason: $reason, description: $description}'
else
  printf 'route=%s\nmodel=%s\nreasoning_effort=%s\nreason=%s\n' "$route" "$model" "$reasoning_effort" "$reason"
fi
