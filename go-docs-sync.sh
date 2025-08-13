#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# file........: go-docs-mirror-md / go-docs-sync.sh
#
# Purpose.....: Create/update a local Markdown mirror of Go docs.
# Includes....:
#   - API docs for all stdlib packages AND all cmd/* tool packages (via gomarkdoc)
#   - Official site docs from golang.org/x/website (_content → Markdown via pandoc)
#   - Blog: copies *.article sources; optional Markdown render (see Makefile: blog-md)
#   - Release notes: release history + per-version pages from go.dev (HTML → Markdown)
#   - Language spec: doc/go_spec.html → Markdown
# Excludes....:
#   - Go Tour (tour/)
# Optional....:
#   - Unexported/private symbols (run with -u or use `make sync-u`)
# Usage.......:
#   ./go-docs-sync.sh [OUTPUT_ROOT]
#   - [OUTPUT_ROOT]: defaults to $PWD
# Env.........:
#   CONCURRENCY (parallelism), SCRATCH (default: $ROOT/_tmp), GIT_RETRIES (default: 4)
# Requirements:
#   bash, go (>=1.18), git, curl, pandoc, rsync, xargs, grep, find, sort, wc
# License.....:
#   - License: GNU Affero General Public License v3.0 **or later** (AGPL-3.0-or-later)
#   - All source files must contain the SPDX header; see LICENSE for the full text.
#   - If you modify and run this over a network, you must offer the complete
#     Corresponding Source to users who interact with it (AGPL §13).
#   - Contributions are accepted under the same license.
#   - © 2025 Bad3r <@> unsigned <.> sh
#
set -euo pipefail

# --- config ---------------------------------------------------------------
# Sanitize ROOT: trim trailing whitespace and canonicalize to absolute path
ROOT_RAW="${1:-$PWD}"
ROOT="$(printf '%s' "$ROOT_RAW" | sed -e 's/[[:space:]]\+$//')"
case "$ROOT" in
  /*) ;;                              # already absolute
  *)  ROOT="$(cd "$ROOT" && pwd -P)";;# canonicalize relative path
esac

SCRATCH="${SCRATCH:-$ROOT/_tmp}"          # keep temporary artifacts *inside* the repo
STD_CMD_LIST="$SCRATCH/packages.txt"

# API docs root (avoid polluting $ROOT)
PKG_MD_ROOT="$ROOT/docs"

# website clone + outputs
SITE_DIR="$ROOT/_site_src"                # cloned x/website source
SITE_MD="$ROOT/site-md"                   # converted + copied site docs (Markdown)

# release notes (HTML cache + MD output)
REL_HTML_DIR="$SCRATCH/release-notes/html"
REL_MD_DIR="$ROOT/release-notes/md"

# language spec (HTML cache + MD output)
SPEC_HTML="$SCRATCH/go_spec.html"
SPEC_MD="$SITE_MD/ref/spec.md"

# Detect CPU count (Linux/macOS) for parallel xargs
if command -v nproc >/dev/null 2>&1; then
  CONCURRENCY="${CONCURRENCY:-$(nproc)}"
elif command -v sysctl >/dev/null 2>&1; then
  CONCURRENCY="${CONCURRENCY:-$(sysctl -n hw.ncpu)}"
else
  CONCURRENCY="${CONCURRENCY:-4}"
fi

# --- helpers --------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { printf "Missing dependency: %s\n" "$1"; exit 1; }; }

clone_or_refresh() {
  local url="$1" dir="$2" owner="$3" repo="$4"
  local tries="${GIT_RETRIES:-4}" i=1
  if [ -d "$dir/.git" ]; then
    printf "Updating %s…\n" "$dir"
    git -C "$dir" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch --depth=1 origin \
      && git -C "$dir" reset --hard FETCH_HEAD >/dev/null
    return
  fi
  while [ "$i" -le "$tries" ]; do
    printf "Cloning %s (attempt %d/%d)…\n" "$url" "$i" "$tries"
    if GIT_TERMINAL_PROMPT=0 git \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
        clone --filter=blob:none --depth=1 --single-branch "$url" "$dir" >/dev/null 2>&1; then
      return
    fi
    sleep $((i*2)); i=$((i+1))
  done
  printf "Git clone failed after %d attempts. Falling back to tarball…\n" "$tries"
  for branch in master main; do
    local tarurl="https://codeload.github.com/${owner}/${repo}/tar.gz/refs/heads/${branch}"
    local tgz="$SCRATCH/${repo}-${branch}.tgz"
    if curl -fsSL "$tarurl" -o "$tgz"; then
      mkdir -p "$dir"
      tar -xzf "$tgz" -C "$SCRATCH"
      local src; src="$(find "$SCRATCH" -maxdepth 1 -type d -name "${repo}-*" | head -n1 || true)"
      if [ -n "$src" ] && [ -d "$src" ]; then
        rsync -a "$src/" "$dir/" >/dev/null
        return
      fi
    fi
  done
  printf "ERROR: Unable to obtain %s. Check your network and retry.\n" "$url"
  exit 1
}

# --- preflight ------------------------------------------------------------
mkdir -p "$ROOT" "$SCRATCH" "$PKG_MD_ROOT"
for c in go git curl pandoc rsync xargs grep find sort wc; do need "$c"; done

# Ensure Go bin is in PATH so gomarkdoc is runnable after install
GOPATH_BIN="$(go env GOPATH)/bin"
export PATH="$GOPATH_BIN:${PATH}"

# --- install tools --------------------------------------------------------
printf "Installing gomarkdoc…\n"
go install github.com/princjef/gomarkdoc/cmd/gomarkdoc@latest

# --- enumerate ALL std + cmd packages (source-only) -----------------------
# Keep only packages that actually have Go/cgo source files for this toolchain.
# Capture both import path and physical dir: "<import>|<dir>"
printf "Enumerating std and cmd packages (source-only)…\n"
mkdir -p "$(dirname "$STD_CMD_LIST")"
go list -f '{{if or (gt (len .GoFiles) 0) (gt (len .CgoFiles) 0)}}{{.ImportPath}}|{{.Dir}}{{end}}' std cmd \
  | sed '/^$/d' | sort -u > "$STD_CMD_LIST"

# --- generate Markdown for each package (cd into pkg dir) -----------------
PKG_COUNT="$(wc -l < "$STD_CMD_LIST" | tr -d ' ')"
printf "Generating Markdown for %s packages (parallel=%s)…\n" "$PKG_COUNT" "$CONCURRENCY"

SKIP_LOG="$SCRATCH/gomarkdoc-skipped.txt"
: > "$SKIP_LOG"

# Run gomarkdoc from within the package directory to improve symbol resolution.
# We still write under docs/<import>/README.md using the template.
xargs -a "$STD_CMD_LIST" -P "$CONCURRENCY" -I {} sh -c '
  IFS="|" read -r import dir <<EOF
{}
EOF
  outdir="'"$PKG_MD_ROOT"'/$import"
  mkdir -p "$outdir"
  if [ -d "$dir" ]; then
    ( cd "$dir" && gomarkdoc --output "'"$PKG_MD_ROOT"'"/{{.ImportPath}}/README.md . ) \
      || printf "skip (gomarkdoc failed): %s\n" "$import" >> "'"$SKIP_LOG"'"
  else
    printf "skip (missing dir): %s -> %s\n" "$import" "$dir" >> "'"$SKIP_LOG"'"
  fi
' >/dev/null

if [ -s "$SKIP_LOG" ]; then
  printf "Note: some packages were skipped. See %s\n" "$SKIP_LOG"
fi

# --- mirror official site docs (x/website), excluding tour/ ---------------
clone_or_refresh "https://github.com/golang/website.git" "$SITE_DIR" "golang" "website"

printf "Converting site HTML -> Markdown (excluding tour/)…\n"
find "$SITE_DIR/_content" -type f -name '*.html' ! -path "$SITE_DIR/_content/tour/*" -print0 \
| while IFS= read -r -d '' f; do
    rel="${f#"$SITE_DIR/_content/"}"
    out="$SITE_MD/${rel%.html}.md"
    mkdir -p "$(dirname "$out")"
    pandoc -f html -t gfm -o "$out" "$f"
  done

# Copy native Markdown from _content/, but exclude tour/
rsync -a \
  --include='*/' --include='*.md' --exclude='/tour/**' --exclude='*' \
  "$SITE_DIR/_content/" "$SITE_MD/"

# Blog sources (*.article) are kept (not tour)
rsync -a --include='*/' --include='*.article' --exclude='*' \
  "$SITE_DIR/blog/_content/" "$SITE_MD/blog/"

# --- add language spec (convert to Markdown) ------------------------------
printf "Fetching and converting Go language spec…\n"
mkdir -p "$(dirname "$SPEC_MD")" "$(dirname "$SPEC_HTML")"
curl -fsSL https://raw.githubusercontent.com/golang/go/master/doc/go_spec.html -o "$SPEC_HTML"
pandoc -f html -t gfm -o "$SPEC_MD" "$SPEC_HTML"

# --- add release history + per-version release notes ----------------------
printf "Fetching and converting release notes…\n"
mkdir -p "$REL_HTML_DIR" "$REL_MD_DIR"
curl -fsSL https://go.dev/doc/devel/release -o "$REL_HTML_DIR/release-history.html"
pandoc -f html -t gfm -o "$REL_MD_DIR/release-history.md" "$REL_HTML_DIR/release-history.html"

grep -oE '/doc/go1[^"]+' "$REL_HTML_DIR/release-history.html" | sort -u | while read -r path; do
  base="$(basename "$path")"   # e.g., go1.24
  curl -fsSL "https://go.dev${path}" -o "$REL_HTML_DIR/${base}.html"
  pandoc -f html -t gfm -o "$REL_MD_DIR/${base}.md" "$REL_HTML_DIR/${base}.html"
done

printf "Done.\n"
printf "API docs:           %s\n" "$PKG_MD_ROOT"
printf "Site docs (MD):     %s\n" "$SITE_MD"
printf "Release notes (MD): %s\n" "$REL_MD_DIR"
