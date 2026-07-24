#!/usr/bin/env bash
set -euo pipefail

clowder_root() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  cd -- "$script_dir/.." && pwd -P
}

die() {
  printf 'clowder: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'clowder: warning: %s\n' "$*" >&2
}

info() {
  printf 'clowder: %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

resolve_repo() {
  local candidate="${1:-$PWD}"
  [[ -d "$candidate" ]] || die "repository path does not exist: $candidate"
  git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || die "not a Git repository: $candidate"
}

yaml_scalar() {
  local file=$1
  local path=$2
  ruby -r yaml -e '
    value = YAML.safe_load(File.read(ARGV[0]), aliases: true)
    ARGV[1].split(".").each do |key|
      value = value.is_a?(Hash) ? value[key] : nil
    end
    exit 1 if value.nil? || value.is_a?(Hash) || value.is_a?(Array)
    puts value
  ' "$file" "$path"
}

validate_yaml() {
  local file=$1
  ruby -r yaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$file" >/dev/null
}

validate_json() {
  local file=$1
  jq empty "$file" >/dev/null
}

schema_validation_errors() {
  local schema=$1
  local data=$2
  local root output
  root="$(clowder_root)"
  if ! command -v node >/dev/null 2>&1; then
    printf '%s\n' '$: required command is unavailable: node'
    return 0
  fi
  output="$(node "$root/scripts/validate-schema.mjs" "$schema" "$data" 2>/dev/null || true)"
  if ! jq -e '.ok | type == "boolean"' <<<"$output" >/dev/null 2>&1; then
    printf '%s\n' '$: schema validator failed without a structured result'
    return 0
  fi
  jq -r '.errors[] | "\(.path): \(.message)"' <<<"$output"
}

sha256_file() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    die "a SHA-256 utility is unavailable (shasum or sha256sum)"
  fi
}

sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    die "a SHA-256 utility is unavailable (shasum or sha256sum)"
  fi
}

upstream_skill_is_locked() {
  local lock_file=$1
  local skill_name=$2
  jq -e --arg name "$skill_name" '.skills | has($name)' "$lock_file" >/dev/null 2>&1
}

skill_tree_matches_lock() {
  local skill_root=$1
  local lock_file=$2
  local skill_name=$3
  local expected_files actual_files relative_file expected_hash

  [[ -d "$skill_root" && ! -L "$skill_root" ]] || return 1
  upstream_skill_is_locked "$lock_file" "$skill_name" || return 1
  expected_files="$(jq -c --arg name "$skill_name" '.skills[$name].files | keys | sort' "$lock_file")"
  actual_files="$(ruby -r json -e '
    root = ARGV.fetch(0)
    files = Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) || File.symlink?(path) }
    puts JSON.generate(files.map { |path| path.delete_prefix("#{root}/") }.sort)
  ' "$skill_root")"
  [[ "$actual_files" == "$expected_files" ]] || return 1

  while IFS= read -r relative_file; do
    case "$relative_file" in
      /*|../*|*/../*|*/..) return 1 ;;
    esac
    [[ -f "$skill_root/$relative_file" && ! -L "$skill_root/$relative_file" ]] || return 1
    expected_hash="$(jq -r --arg name "$skill_name" --arg file "$relative_file" '.skills[$name].files[$file]' "$lock_file")"
    [[ "$(sha256_file "$skill_root/$relative_file")" == "$expected_hash" ]] || return 1
  done < <(jq -r --arg name "$skill_name" '.skills[$name].files | keys[]' "$lock_file")
}

clowder_skill_install_name() {
  local skill_name=$1
  case "$skill_name" in
    clowder-*) printf '%s\n' "$skill_name" ;;
    *) printf 'clowder-%s\n' "$skill_name" ;;
  esac
}

approval_revision() {
  local repo=$1
  local feature_dir=$2
  local kind=$3
  case "$kind" in
    prd)
      sha256_file "$feature_dir/PRD.md"
      ;;
    architecture)
      {
        printf 'path:%s\nbytes:%s\n' 'TECHNICAL_DESIGN.md' "$(wc -c < "$feature_dir/TECHNICAL_DESIGN.md" | tr -d '[:space:]')"
        cat "$feature_dir/TECHNICAL_DESIGN.md"
        printf '\n'
        ruby -r yaml -e '
          data = YAML.safe_load(File.read(ARGV[0]), aliases: true)
          Array(data.dig("artifacts", "adrs")).each { |path| puts path }
        ' "$feature_dir/feature.yaml" | while IFS= read -r relative_path; do
          [[ -n "$relative_path" ]] || continue
          adr_path="$repo/$relative_path"
          [[ -f "$adr_path" ]] || die "listed ADR does not exist: $adr_path"
          printf 'path:%s\nbytes:%s\n' "$relative_path" "$(wc -c < "$adr_path" | tr -d '[:space:]')"
          cat "$adr_path"
          printf '\n'
        done
      } | sha256_stream
      ;;
    review|testing|merge|residual-risk)
      git -C "$repo" rev-parse HEAD
      ;;
    *)
      die "unknown approval kind: $kind"
      ;;
  esac
}

merge_attestation_revision() {
  local feature_dir=$1
  local relative_path
  {
    for relative_path in PULL_REQUEST.md evidence/reviewer.md evidence/tester.md; do
      [[ -f "$feature_dir/$relative_path" ]] || die "missing merge attestation file: $relative_path"
      printf 'path:%s\nbytes:%s\n' "$relative_path" "$(wc -c < "$feature_dir/$relative_path" | tr -d '[:space:]')"
      cat "$feature_dir/$relative_path"
      printf '\n'
    done
    printf '%s\n' 'manifest-without-merge-approval:'
    ruby -r yaml -r json -e '
      def canonical(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, canonical(value[key])] }
        when Array
          value.map { |item| canonical(item) }
        else
          value
        end
      end
      data = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
      data = data.dup
      approvals = (data["approvals"] || {}).dup
      approvals.delete("merge")
      data["approvals"] = approvals
      print JSON.generate(canonical(data))
    ' "$feature_dir/feature.yaml"
    printf '\n'
  } | sha256_stream
}

is_feature_attestation_path() {
  local feature_relative=$1
  local candidate=$2
  [[ "$candidate" == "$feature_relative/feature.yaml" \
    || "$candidate" == "$feature_relative/PULL_REQUEST.md" \
    || "$candidate" == "$feature_relative/evidence/reviewer.md" \
    || "$candidate" == "$feature_relative/evidence/tester.md" ]]
}

non_attestation_changes_since() {
  local repo=$1
  local feature_dir=$2
  local revision=$3
  local include_worktree=${4:-false}
  local feature_relative
  feature_relative="${feature_dir#"$repo/"}"
  [[ "$feature_relative" != "$feature_dir" ]] || die "Feature directory is outside the product repository: $feature_dir"

  {
    git -C "$repo" -c diff.renames=false diff --name-only "$revision"..HEAD
    if [[ "$include_worktree" == true ]]; then
      git -C "$repo" -c diff.renames=false diff --name-only HEAD
      git -C "$repo" -c diff.renames=false diff --cached --name-only HEAD
      git -C "$repo" ls-files --others --exclude-standard
    fi
  } | awk 'NF && !seen[$0]++' | while IFS= read -r changed_path; do
    is_feature_attestation_path "$feature_relative" "$changed_path" || printf '%s\n' "$changed_path"
  done
}

valid_jira_key() {
  [[ "$1" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]
}

valid_lifecycle_phase() {
  case "$1" in
    'Intake'|'Discovery'|'Feature Definition'|'PRD'|'Design'|'Test Planning'|'Ready for Development'|'Orchestration'|'Development'|'Developer Verification'|'Testing'|'Review'|'Remediation'|'Ready for Merge'|'Production'|'Complete'|'Needs Information'|'Rejected') return 0 ;;
    *) return 1 ;;
  esac
}

lifecycle_phase_label() {
  local phase=$1
  valid_lifecycle_phase "$phase" || return 1
  printf '%s\n' "${phase// /-}"
}

lifecycle_label_phase() {
  local label=$1
  local phase="${label//-/ }"
  valid_lifecycle_phase "$phase" || return 1
  printf '%s\n' "$phase"
}

valid_slug() {
  [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

normalize_slug() {
  local value=$1
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$value" ]] || die "slug is empty after normalization"
  valid_slug "$value" || die "slug is invalid: $value"
  printf '%s\n' "$value"
}

worktree_for_branch() {
  local repo=$1
  local branch=$2
  git -C "$repo" worktree list --porcelain | awk -v wanted="branch refs/heads/$branch" '
    $1 == "worktree" { path = substr($0, 10) }
    $0 == wanted { print path; exit }
  '
}

supacode_repo_identifier() {
  local repo=$1
  ruby -r uri -e 'print URI::DEFAULT_PARSER.escape(ARGV[0] + "/", /[^A-Za-z0-9_.~-]/)' "$repo"
}

deterministic_uuid() {
  local seed=$1
  ruby -r digest -e '
    value = Digest::SHA256.hexdigest(ARGV.fetch(0))[0, 32]
    value[12] = "5"
    value[16] = ((value[16].to_i(16) & 0x3) | 0x8).to_s(16)
    puts [value[0, 8], value[8, 4], value[12, 4], value[16, 4], value[20, 12]].join("-")
  ' "$seed"
}

path_is_within() {
  local child=$1
  local parent=$2
  if [[ -d "$child" ]]; then
    child="$(cd -- "$child" && pwd -P)"
  else
    child="$(cd -- "$(dirname -- "$child")" && pwd -P)/$(basename -- "$child")"
  fi
  parent="$(cd -- "$parent" && pwd -P)"
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

repo_config() {
  local repo=$1
  local config="$repo/.clowder/project.yaml"
  [[ -f "$config" ]] || die "missing project configuration: $config"
  validate_yaml "$config" || die "invalid YAML: $config"
  printf '%s\n' "$config"
}

update_yaml_values() {
  local file=$1
  shift
  ruby -r yaml -e '
    file = ARGV.shift
    data = YAML.safe_load(File.read(file), aliases: true)
    until ARGV.empty?
      path = ARGV.shift.split(".")
      value = ARGV.shift
      cursor = data
      path[0...-1].each { |key| cursor = cursor.fetch(key) }
      cursor[path[-1]] = value
    end
    File.write(file, data.to_yaml)
  ' "$file" "$@"
}

render_template() {
  local source=$1
  local target=$2
  local jira=$3
  local slug=$4
  local name=$5
  ruby -e '
    source, target, jira, slug, name = ARGV
    text = File.read(source)
    text = text.gsub("JIRA-123", jira).gsub("feature-name", slug).gsub("Feature Name", name)
    File.write(target, text)
  ' "$source" "$target" "$jira" "$slug" "$name"
}
