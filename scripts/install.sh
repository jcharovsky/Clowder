#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

codex_home=""
link=false
force=false
skill_lock="$ROOT/skill-lock.json"

usage() {
  cat <<'EOF'
Usage: install.sh --codex-home PATH [--link] [--force]

Install pinned Clowder runtime dependencies, 5 role definitions, 3 native skills, and 16 bundled upstream skills.
Native files may be linked with --link. Integrity-locked upstream skills are always copied.
Existing role and native skill files are preserved unless --force is supplied.
An installed upstream skill with different content is rejected unless --force is supplied.
EOF
}

while (($# > 0)); do
  case "$1" in
    --codex-home) codex_home=${2:?missing value for --codex-home}; shift 2 ;;
    --link) link=true; shift ;;
    --force) force=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n "$codex_home" ]] || { usage >&2; exit 2; }
[[ "$codex_home" = /* ]] || { printf '%s\n' '--codex-home must be an absolute path' >&2; exit 2; }
for command_name in node npm jq ruby; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'required command is unavailable: %s\n' "$command_name" >&2; exit 1; }
done
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  printf '%s\n' 'required SHA-256 utility is unavailable: shasum or sha256sum' >&2
  exit 1
fi

[[ -f "$skill_lock" ]] || { printf '%s\n' 'missing skill-lock.json' >&2; exit 1; }
while IFS= read -r skill_name; do
  bundled_skill="$ROOT/skills/$skill_name"
  if ! skill_tree_matches_lock "$bundled_skill" "$skill_lock" "$skill_name"; then
    printf 'bundled upstream skill differs from skill-lock.json: %s\n' "$skill_name" >&2
    exit 1
  fi
done < <(jq -r '.skills | keys[]' "$skill_lock")

upstream_skill_roots=("${HOME:?}/.agents/skills" "$codex_home/skills")
while IFS= read -r skill_name; do
  for upstream_skill_root in "${upstream_skill_roots[@]}"; do
    target="$upstream_skill_root/$skill_name"
    if [[ -e "$target" || -L "$target" ]]; then
      if ! skill_tree_matches_lock "$target" "$skill_lock" "$skill_name" && [[ "$force" != true ]]; then
        printf 'conflicting installed skill: %s at %s; rerun with --force to replace it\n' "$skill_name" "$target" >&2
        exit 1
      fi
    fi
  done
done < <(jq -r '.skills | keys[]' "$skill_lock")

(cd -- "$ROOT" && npm ci --ignore-scripts --no-audit --no-fund >/dev/null)

mkdir -p "$codex_home/agents"
for role_file in "$SCRIPT_DIR"/../.codex/agents/*.toml; do
  role_name="$(basename -- "$role_file")"
  target="$codex_home/agents/clowder-$role_name"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$force" != true ]]; then
      printf 'preserved %s\n' "$target"
      continue
    fi
    rm -f -- "$target"
  fi
  if [[ "$link" == true ]]; then
    ln -s "$role_file" "$target"
  else
    cp "$role_file" "$target"
  fi
  printf 'installed %s\n' "$target"
done

mkdir -p "$codex_home/skills"
for skill_dir in "$ROOT"/skills/*; do
  [[ -d "$skill_dir" ]] || continue
  skill_name="$(basename -- "$skill_dir")"
  if upstream_skill_is_locked "$skill_lock" "$skill_name"; then
    continue
  fi
  installed_name="$(clowder_skill_install_name "$skill_name")"
  target="$codex_home/skills/$installed_name"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$force" != true ]]; then
      printf 'preserved %s\n' "$target"
      continue
    fi
    rm -rf -- "$target"
  fi
  if [[ "$link" == true ]]; then
    ln -s "$skill_dir" "$target"
  else
    cp -R "$skill_dir" "$target"
  fi
  printf 'installed %s\n' "$target"
done

while IFS= read -r skill_name; do
  bundled_skill="$ROOT/skills/$skill_name"
  installed_skill_found=false
  for upstream_skill_root in "${upstream_skill_roots[@]}"; do
    target="$upstream_skill_root/$skill_name"
    if [[ ! -e "$target" && ! -L "$target" ]]; then
      continue
    fi
    installed_skill_found=true
    if skill_tree_matches_lock "$target" "$skill_lock" "$skill_name"; then
      printf 'reused %s\n' "$target"
      continue
    fi
    rm -rf -- "$target"
    mkdir -p "$upstream_skill_root"
    cp -R "$bundled_skill" "$target"
    printf 'replaced %s\n' "$target"
  done
  if [[ "$installed_skill_found" != true ]]; then
    target="$codex_home/skills/$skill_name"
    cp -R "$bundled_skill" "$target"
    printf 'installed %s\n' "$target"
  fi
done < <(jq -r '.skills | keys[]' "$skill_lock")

printf '%s\n' 'Clowder installation complete.'
printf '%s\n' "Add this alias after reviewing it: alias Clowder='$SCRIPT_DIR/clowder'"
printf '%s\n' "Onboard a consumer repository with: $SCRIPT_DIR/onboard.sh --repo /path/to/repository"
printf '%s\n' "Run health checks with: $SCRIPT_DIR/doctor.sh --repo /path/to/repository"
