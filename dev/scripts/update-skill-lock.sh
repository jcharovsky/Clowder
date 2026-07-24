#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
skills_root=""
source_commit=""

usage() {
  printf '%s\n' 'Usage: update-skill-lock.sh --skills-root PATH --source-commit COMMIT'
}

while (($# > 0)); do
  case "$1" in
    --skills-root) skills_root=${2:?missing value for --skills-root}; shift 2 ;;
    --source-commit) source_commit=${2:?missing value for --source-commit}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n "$skills_root" ]] || { usage >&2; exit 2; }
[[ -d "$skills_root" ]] || { printf 'skills directory does not exist: %s\n' "$skills_root" >&2; exit 1; }
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { printf '%s\n' '--source-commit must be a full 40-character Git commit' >&2; exit 2; }
actual_source_commit="$(git -C "$skills_root" rev-parse HEAD 2>/dev/null || true)"
[[ "$actual_source_commit" == "$source_commit" ]] || { printf 'skills checkout is at %s, expected %s\n' "${actual_source_commit:-no Git commit}" "$source_commit" >&2; exit 1; }
[[ -z "$(git -C "$skills_root" status --short)" ]] || { printf '%s\n' 'skills checkout must be clean before lock refresh' >&2; exit 1; }

ruby -r json -r digest -e '
  lock_file, skills_root, source_commit = ARGV
  data = JSON.parse(File.read(lock_file))
  source_paths = {
    "triage" => "skills/engineering/triage",
    "grilling" => "skills/productivity/grilling",
    "grill-with-docs" => "skills/engineering/grill-with-docs",
    "to-spec" => "skills/engineering/to-spec",
    "to-tickets" => "skills/engineering/to-tickets",
    "codebase-design" => "skills/engineering/codebase-design",
    "domain-modeling" => "skills/engineering/domain-modeling",
    "prototype" => "skills/engineering/prototype",
    "implement" => "skills/engineering/implement",
    "tdd" => "skills/engineering/tdd",
    "diagnosing-bugs" => "skills/engineering/diagnosing-bugs",
    "resolving-merge-conflicts" => "skills/engineering/resolving-merge-conflicts",
    "code-review" => "skills/engineering/code-review",
    "handoff" => "skills/productivity/handoff",
    "wizard" => "skills/engineering/wizard",
    "writing-for-agents" => "skills/productivity/writing-for-agents"
  }
  reviewed_files = {
    "triage" => ["SKILL.md", "AGENT-BRIEF.md", "OUT-OF-SCOPE.md", "agents/openai.yaml"],
    "grilling" => ["SKILL.md", "agents/openai.yaml"],
    "grill-with-docs" => ["SKILL.md", "agents/openai.yaml"],
    "to-spec" => ["SKILL.md", "agents/openai.yaml"],
    "to-tickets" => ["SKILL.md", "agents/openai.yaml"],
    "codebase-design" => ["SKILL.md", "DEEPENING.md", "DESIGN-IT-TWICE.md", "agents/openai.yaml"],
    "domain-modeling" => ["SKILL.md", "ADR-FORMAT.md", "CONTEXT-FORMAT.md", "agents/openai.yaml"],
    "prototype" => ["SKILL.md", "LOGIC.md", "UI.md", "agents/openai.yaml"],
    "implement" => ["SKILL.md", "agents/openai.yaml"],
    "tdd" => ["SKILL.md", "tests.md", "mocking.md", "agents/openai.yaml"],
    "diagnosing-bugs" => ["SKILL.md", "scripts/hitl-loop.template.sh", "agents/openai.yaml"],
    "resolving-merge-conflicts" => ["SKILL.md", "agents/openai.yaml"],
    "code-review" => ["SKILL.md", "agents/openai.yaml"],
    "handoff" => ["SKILL.md", "agents/openai.yaml"],
    "wizard" => ["SKILL.md", "template.sh", "agents/openai.yaml"],
    "writing-for-agents" => ["SKILL.md", "SKILL-MECHANICS.md", "agents/openai.yaml"]
  }
  data.fetch("skills").each do |name, entry|
    files = reviewed_files.fetch(name) { abort "missing reviewed file manifest for skill: #{name}" }
    source_path = source_paths.fetch(name) { abort "missing upstream path for skill: #{name}" }
    entry["path"] = source_path
    entry["files"] = files.sort.to_h do |relative|
      source = File.join(skills_root, source_path, relative)
      abort "missing skill source: #{source}" unless File.file?(source) && !File.symlink?(source)
      [relative, Digest::SHA256.file(source).hexdigest]
    end
    entry.delete("sha256")
  end
  data["lockVersion"] = 2
  data["sourceCommit"] = source_commit
  data["reviewedAt"] = Time.now.utc.strftime("%Y-%m-%d")
  File.write(lock_file, JSON.pretty_generate(data) + "\n")
' "$ROOT/skill-lock.json" "$skills_root" "$source_commit"

printf '%s\n' 'skill-lock.json refreshed.'
