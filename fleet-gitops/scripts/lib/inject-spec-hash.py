#!/usr/bin/env python3
"""Inject fleet.example.com/spec-hash annotation into Job metadata in YAML files.

Usage: inject-spec-hash.py <file> <hash>

Handles:
- Multi-doc YAML (only modifies Job documents)
- Existing annotations block (merges)
- Existing spec-hash annotation (replaces value)
- Missing annotations block (creates after name:)
"""
import re
import sys

ANNOTATION_KEY = "fleet.example.com/spec-hash"


def inject_hash(content: str, hash_value: str) -> str:
    """Process multi-doc YAML, inject annotation into Job documents only."""
    # Split on YAML document separators (--- at start of line)
    parts = re.split(r"(^---[ \t]*$)", content, flags=re.MULTILINE)
    result = []
    for part in parts:
        if part.strip() == "---":
            result.append(part)
        elif re.search(r"^\s*kind:\s*Job\s*$", part, re.MULTILINE):
            result.append(_inject_into_job(part, hash_value))
        else:
            result.append(part)
    return "".join(result)


def _inject_into_job(doc: str, hash_value: str) -> str:
    """Inject spec-hash annotation into a single Job YAML document."""
    lines = doc.split("\n")
    new_lines = []
    i = 0

    while i < len(lines):
        line = lines[i]

        # Detect top-level metadata: block
        if re.match(r"^metadata:\s*$", line):
            new_lines.append(line)
            i += 1

            # Determine indent of metadata children
            meta_indent = None
            for j in range(i, len(lines)):
                if lines[j].strip() and not lines[j].startswith("#"):
                    meta_indent = len(lines[j]) - len(lines[j].lstrip())
                    break
            if meta_indent is None:
                meta_indent = 2

            # Scan ahead: does annotations: already exist at metadata level?
            ann_line_idx = None
            for j in range(i, len(lines)):
                stripped = lines[j].strip()
                if not stripped or stripped.startswith("#"):
                    continue
                indent = len(lines[j]) - len(lines[j].lstrip())
                if indent < meta_indent:
                    break  # Left metadata block
                if indent == meta_indent and stripped.startswith("annotations:"):
                    ann_line_idx = j
                    break

            if ann_line_idx is not None:
                # annotations: exists — process lines up to it, then merge
                while i <= ann_line_idx:
                    new_lines.append(lines[i])
                    i += 1
                # Now inject/replace within annotations block
                ann_indent = meta_indent + 2
                found_existing = False
                while i < len(lines):
                    stripped = lines[i].strip()
                    indent = len(lines[i]) - len(lines[i].lstrip())
                    # Still inside annotations block?
                    if stripped and not stripped.startswith("#") and indent <= meta_indent:
                        break
                    if ANNOTATION_KEY in lines[i]:
                        new_lines.append(
                            f'{" " * ann_indent}{ANNOTATION_KEY}: "{hash_value}"'
                        )
                        found_existing = True
                        i += 1
                        continue
                    new_lines.append(lines[i])
                    i += 1
                if not found_existing:
                    # Append as last annotation (before the line that broke us out)
                    new_lines.append(
                        f'{" " * ann_indent}{ANNOTATION_KEY}: "{hash_value}"'
                    )
            else:
                # No annotations: block — insert after name: line
                inserted = False
                while i < len(lines):
                    stripped = lines[i].strip()
                    indent = len(lines[i]) - len(lines[i].lstrip())
                    # Left metadata block?
                    if stripped and not stripped.startswith("#") and indent < meta_indent:
                        if not inserted:
                            new_lines.append(f'{" " * meta_indent}annotations:')
                            new_lines.append(
                                f'{" " * (meta_indent + 2)}{ANNOTATION_KEY}: "{hash_value}"'
                            )
                            inserted = True
                        new_lines.append(lines[i])
                        i += 1
                        break
                    new_lines.append(lines[i])
                    if not inserted and stripped.startswith("name:") and indent == meta_indent:
                        new_lines.append(f'{" " * meta_indent}annotations:')
                        new_lines.append(
                            f'{" " * (meta_indent + 2)}{ANNOTATION_KEY}: "{hash_value}"'
                        )
                        inserted = True
                    i += 1
            continue

        new_lines.append(line)
        i += 1

    return "\n".join(new_lines)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <file> <hash>", file=sys.stderr)
        sys.exit(1)
    filepath, hash_value = sys.argv[1], sys.argv[2]
    with open(filepath) as f:
        content = f.read()
    result = inject_hash(content, hash_value)
    with open(filepath, "w") as f:
        f.write(result)
