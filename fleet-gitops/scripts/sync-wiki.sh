#!/usr/bin/env bash
# =============================================================================
# sync-wiki.sh — Bidirectional sync between docs/ and GitLab wiki
# =============================================================================
# Converts between the docs/ subdirectory structure and the flat file format
# used by GitLab/GitHub wikis. Handles link rewriting and sidebar generation.
#
# Usage:
#   ./sync-wiki.sh docs-to-wiki --output /path/to/wiki    # docs/ -> flat wiki
#   ./sync-wiki.sh wiki-to-docs --input /path/to/wiki     # flat wiki -> docs/
#   ./sync-wiki.sh generate-sidebar                        # emit _sidebar.md
#
# File mapping:
#   docs/architecture/overview.md      -> architecture-overview.md
#   docs/developer-guide/quickstart.md -> developer-guide-quickstart.md
#   docs/getting-started.md            -> getting-started.md
#   docs/README.md                     -> home.md
#   docs/*/index.md                    -> <section>.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCS_DIR="${REPO_ROOT}/docs"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()       { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# docs/ path -> wiki filename
# ---------------------------------------------------------------------------
docs_path_to_wiki_name() {
  local rel_path="$1" # relative to docs/, e.g. "architecture/overview.md"

  # Special cases
  if [[ "$rel_path" == "README.md" ]]; then
    echo "home.md"
    return
  fi

  # index.md -> section name (e.g. developer-guide/index.md -> developer-guide.md)
  if [[ "$rel_path" == */index.md ]]; then
    local section
    section=$(dirname "$rel_path" | tr '/' '-')
    echo "${section}.md"
    return
  fi

  # Nested file: architecture/overview.md -> architecture-overview.md
  if [[ "$rel_path" == */* ]]; then
    echo "$rel_path" | sed 's|/|-|g'
    return
  fi

  # Top-level file: getting-started.md -> getting-started.md
  echo "$rel_path"
}

# ---------------------------------------------------------------------------
# wiki filename -> docs/ path
# ---------------------------------------------------------------------------
wiki_name_to_docs_path() {
  local wiki_name="$1" # e.g. "architecture-overview.md"

  # Special cases
  if [[ "$wiki_name" == "home.md" ]]; then
    echo "README.md"
    return
  fi

  if [[ "$wiki_name" == "_sidebar.md" ]]; then
    return # skip sidebar
  fi

  # Known section prefixes
  local sections=("architecture" "developer-guide" "operator-guide")

  for section in "${sections[@]}"; do
    if [[ "$wiki_name" == "${section}-"* ]]; then
      local filename="${wiki_name#${section}-}"
      echo "${section}/${filename}"
      return
    fi
    # Section index: developer-guide.md -> developer-guide/index.md
    if [[ "$wiki_name" == "${section}.md" ]]; then
      echo "${section}/index.md"
      return
    fi
  done

  # No known prefix — top-level file
  echo "$wiki_name"
}

# ---------------------------------------------------------------------------
# Rewrite internal links: docs/ style -> wiki style
# ---------------------------------------------------------------------------
rewrite_links_to_wiki() {
  local content="$1"
  local source_dir="$2" # directory of the source file relative to docs/

  # Rewrite relative links like [text](../architecture/overview.md) or [text](./quickstart.md)
  # to wiki format [text](architecture-overview)
  echo "$content" | sed -E '
    # Cross-directory links: ../architecture/overview.md -> architecture-overview
    s|\]\(\.\.\/([a-zA-Z0-9_-]+)\/([a-zA-Z0-9_.-]+)\.md\)|](\1-\2)|g
    # Same-directory links: ./overview.md -> <current-section>-overview
    # (handled per-file below)
    # Remove .md extension from any remaining markdown links
    s|\]\(([a-zA-Z0-9_-]+)\.md\)|](\1)|g
  '
}

# ---------------------------------------------------------------------------
# Rewrite internal links: wiki style -> docs/ style
# ---------------------------------------------------------------------------
rewrite_links_to_docs() {
  local content="$1"
  local target_dir="$2" # directory of the target file relative to docs/

  local sections=("architecture" "developer-guide" "operator-guide")

  for section in "${sections[@]}"; do
    # architecture-overview -> ../architecture/overview.md (if in different dir)
    # architecture-overview -> ./overview.md (if in same dir)
    if [[ "$target_dir" == "$section" ]]; then
      content=$(echo "$content" | sed -E "s|\]\(${section}-([a-zA-Z0-9_.-]+)\)|](./\1.md)|g")
    else
      content=$(echo "$content" | sed -E "s|\]\(${section}-([a-zA-Z0-9_.-]+)\)|](../${section}/\1.md)|g")
    fi
  done

  # Top-level links without section prefix
  content=$(echo "$content" | sed -E 's|\]\(([a-zA-Z0-9_-]+)\)|](\1.md)|g')

  echo "$content"
}

# ---------------------------------------------------------------------------
# Generate _sidebar.md
# ---------------------------------------------------------------------------
generate_sidebar() {
  local output=""

  output+="**Platform Documentation**\n\n"
  output+="- [Home](home)\n\n"

  # Architecture section
  if [[ -d "${DOCS_DIR}/architecture" ]]; then
    output+="**Architecture**\n"
    while IFS= read -r f; do
      local basename
      basename=$(basename "$f" .md)
      [[ "$basename" == "index" ]] && continue
      [[ "$basename" == "DIAGRAM_REFERENCE" ]] && continue
      local title
      title=$(head -1 "$f" | sed 's/^#* *//')
      [[ -z "$title" ]] && title="$basename"
      output+="- [${title}](architecture-${basename})\n"
    done < <(find "${DOCS_DIR}/architecture" -name "*.md" -not -name "index.md" | sort)
    output+="\n"
  fi

  # Developer Guide section
  if [[ -d "${DOCS_DIR}/developer-guide" ]]; then
    output+="**Developer Guide**\n"
    while IFS= read -r f; do
      local basename
      basename=$(basename "$f" .md)
      [[ "$basename" == "index" ]] && continue
      local title
      title=$(head -1 "$f" | sed 's/^#* *//')
      [[ -z "$title" ]] && title="$basename"
      output+="- [${title}](developer-guide-${basename})\n"
    done < <(find "${DOCS_DIR}/developer-guide" -name "*.md" -not -name "index.md" | sort)
    output+="\n"
  fi

  # Operator Guide section
  if [[ -d "${DOCS_DIR}/operator-guide" ]]; then
    output+="**Operator Guide**\n"
    while IFS= read -r f; do
      local basename
      basename=$(basename "$f" .md)
      [[ "$basename" == "index" ]] && continue
      local title
      title=$(head -1 "$f" | sed 's/^#* *//')
      [[ -z "$title" ]] && title="$basename"
      output+="- [${title}](operator-guide-${basename})\n"
    done < <(find "${DOCS_DIR}/operator-guide" -name "*.md" -not -name "index.md" | sort)
    output+="\n"
  fi

  # Top-level docs
  output+="**Getting Started**\n"
  if [[ -f "${DOCS_DIR}/getting-started.md" ]]; then
    output+="- [Deployment Guide](getting-started)\n"
  fi

  echo -e "$output"
}

# ---------------------------------------------------------------------------
# Command: docs-to-wiki
# ---------------------------------------------------------------------------
cmd_docs_to_wiki() {
  local output_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) output_dir="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -n "$output_dir" ]] || die "Usage: sync-wiki.sh docs-to-wiki --output <dir>"
  mkdir -p "$output_dir"

  local count=0

  # Find all markdown files in docs/
  while IFS= read -r filepath; do
    local rel_path="${filepath#${DOCS_DIR}/}"
    local wiki_name
    wiki_name=$(docs_path_to_wiki_name "$rel_path")
    [[ -z "$wiki_name" ]] && continue

    local source_dir
    source_dir=$(dirname "$rel_path")
    [[ "$source_dir" == "." ]] && source_dir=""

    # Read content and rewrite links
    local content
    content=$(cat "$filepath")
    content=$(rewrite_links_to_wiki "$content" "$source_dir")

    echo "$content" > "${output_dir}/${wiki_name}"
    count=$((count + 1))
  done < <(find "${DOCS_DIR}" -name "*.md" -not -path "*/superpowers/*" -not -path "*/plans/*" | sort)

  # Generate sidebar
  generate_sidebar > "${output_dir}/_sidebar.md"
  count=$((count + 1))

  log_ok "Converted ${count} files to wiki format in ${output_dir}/"
}

# ---------------------------------------------------------------------------
# Command: wiki-to-docs
# ---------------------------------------------------------------------------
cmd_wiki_to_docs() {
  local input_dir=""
  local output_dir="${DOCS_DIR}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input) input_dir="$2"; shift 2 ;;
      --output) output_dir="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -n "$input_dir" ]] || die "Usage: sync-wiki.sh wiki-to-docs --input <dir>"

  local count=0

  for filepath in "${input_dir}"/*.md; do
    [[ -f "$filepath" ]] || continue
    local wiki_name
    wiki_name=$(basename "$filepath")

    # Skip sidebar
    [[ "$wiki_name" == "_sidebar.md" ]] && continue

    local docs_path
    docs_path=$(wiki_name_to_docs_path "$wiki_name")
    [[ -z "$docs_path" ]] && continue

    local target_dir
    target_dir=$(dirname "$docs_path")

    # Read content and rewrite links
    local content
    content=$(cat "$filepath")
    content=$(rewrite_links_to_docs "$content" "$target_dir")

    mkdir -p "${output_dir}/${target_dir}"
    echo "$content" > "${output_dir}/${docs_path}"
    count=$((count + 1))
  done

  log_ok "Converted ${count} wiki files to docs/ format in ${output_dir}/"
}

# ---------------------------------------------------------------------------
# Command: generate-sidebar
# ---------------------------------------------------------------------------
cmd_generate_sidebar() {
  generate_sidebar
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
  docs-to-wiki)      shift; cmd_docs_to_wiki "$@" ;;
  wiki-to-docs)      shift; cmd_wiki_to_docs "$@" ;;
  generate-sidebar)  shift; cmd_generate_sidebar "$@" ;;
  *)
    echo "Usage: sync-wiki.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  docs-to-wiki --output <dir>   Convert docs/ to flat wiki format"
    echo "  wiki-to-docs --input <dir>    Convert flat wiki back to docs/"
    echo "  generate-sidebar              Print _sidebar.md to stdout"
    exit 1
    ;;
esac
