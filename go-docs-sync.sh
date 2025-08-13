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
#   ./go-docs-sync.sh [OUTPUT_ROOT]  # defaults to $PWD
# Env.........:
#   CONCURRENCY (parallelism), SCRATCH (default: $ROOT/_tmp), GOMARKDOC_REF (default: master)
# Requirements:
#   bash, go (>=1.18), git, curl, pandoc, rsync, xargs, grep, find, sort, wc
# License.....:
#   - AGPL-3.0-or-later; see LICENSE. AGPL §13 applies for network use.
#   - © 2025 Bad3r <@> unsigned <.> sh
set -euo pipefail

# --- config ---------------------------------------------------------------
# Sanitize ROOT: trim trailing whitespace and canonicalize to absolute path
ROOT_RAW="${1:-$PWD}"
ROOT="$(printf '%s' "$ROOT_RAW" | sed -e 's/[[:space:]]\+$//')"
case "$ROOT" in /*) ;; *) ROOT="$(cd "$ROOT" && pwd -P)";; esac

SCRATCH="${SCRATCH:-$ROOT/_tmp}"
PKG_MD_ROOT="$ROOT/docs"                   # API docs live here
SITE_DIR="$ROOT/_site_src"                 # x/website clone
SITE_MD="$ROOT/site-md"                    # site content converted to MD
REL_HTML_DIR="$SCRATCH/release-notes/html" # cached HTML
REL_MD_DIR="$ROOT/release-notes/md"        # release notes MD
SPEC_HTML="$SCRATCH/go_spec.html"
SPEC_MD="$SITE_MD/ref/spec.md"

STD_CMD_LIST="$SCRATCH/packages.txt"       # import|dir pairs
SKIP_LOG="$SCRATCH/gomarkdoc-skipped.txt"  # failures only

# Parallelism
if command -v nproc >/dev/null 2>&1; then CONCURRENCY="${CONCURRENCY:-$(nproc)}"
elif command -v sysctl >/dev/null 2>&1; then CONCURRENCY="${CONCURRENCY:-$(sysctl -n hw.ncpu)}"
else CONCURRENCY="${CONCURRENCY:-4}"; fi

# --- helpers --------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { printf "Missing dependency: %s\n" "$1"; exit 1; }; }
mkp() { mkdir -p "$@"; }

# --- preflight ------------------------------------------------------------
mkp "$ROOT" "$SCRATCH" "$PKG_MD_ROOT"
for c in go git curl pandoc rsync xargs grep find sort wc; do need "$c"; done
# export PATH="$(go env GOPATH)/bin:${PATH}"

# --- install tools --------------------------------------------------------
printf "Installing gomarkdoc…\n"
GOMARKDOC_REF="${GOMARKDOC_REF:-master}"   # use master by default for better doc-link support
go install "github.com/princjef/gomarkdoc/cmd/gomarkdoc@${GOMARKDOC_REF}"

# --- enumerate ALL std + cmd packages (source-only) -----------------------
printf "Enumerating std and cmd packages (source-only)…\n"
mkp "$(dirname "$STD_CMD_LIST")"
go list -f '{{if or (gt (len .GoFiles) 0) (gt (len .CgoFiles) 0)}}{{.ImportPath}}|{{.Dir}}{{end}}' std cmd \
  | sed '/^$/d' | sort -u > "$STD_CMD_LIST"

# --- generate Markdown for each package (cd into pkg dir) -----------------
PKG_COUNT="$(wc -l < "$STD_CMD_LIST" | tr -d ' ')"
printf "Generating Markdown for %s packages (parallel=%s)…\n" "$PKG_COUNT" "$CONCURRENCY"
: > "$SKIP_LOG"

# Run gomarkdoc from inside each package directory; let warnings print to STDERR
xargs -a "$STD_CMD_LIST" -P "$CONCURRENCY" -I {} sh -c '
  IFS="|" read -r import dir <<EOF
{}
EOF
  outdir="'"$PKG_MD_ROOT"'/$import"
  mkdir -p "$outdir"
  if [ -d "$dir" ]; then
    ( cd "$dir" && gomarkdoc --output "'"$PKG_MD_ROOT"'/{{.ImportPath}}/README.md . ) \
      || printf "skip (gomarkdoc failed): %s\n" "$import" >> "'"$SKIP_LOG"'"
  else
    printf "skip (missing dir): %s -> %s\n" "$import" "$dir" >> "'"$SKIP_LOG"'"
  fi
'

[ -s "$SKIP_LOG" ] && printf "Note: some packages were skipped. See %s\n" "$SKIP_LOG"

# --- mirror official site docs (x/website), excluding tour/ ---------------
if [ ! -d "$SITE_DIR" ]; then
  printf "Cloning golang.org/x/website (shallow)…\n"
  git clone --depth=1 https://github.com/golang/website.git "$SITE_DIR" >/dev/null
else
  printf "Updating golang.org/x/website…\n"
  git -C "$SITE_DIR" pull --ff-only >/dev/null
fi

printf "Converting site HTML -> Markdown (excluding tour/)…\n"
mkp "$SITE_MD"
find "$SITE_DIR/_content" -type f -name '*.html' ! -path "$SITE_DIR/_content/tour/*" -print0 \
| while IFS= read -r -d '' f; do
    rel="${f#"$SITE_DIR/_content/"}"
    out="$SITE_MD/${rel%.html}.md"
    mkp "$(dirname "$out")"
    pandoc -f html -t gfm -o "$out" "$f"
  done

# Copy native Markdown from _content/, but exclude tour/
rsync -a --include='*/' --include='*.md' --exclude='/tour/**' --exclude='*' \
  "$SITE_DIR/_content/" "$SITE_MD/"

# Blog sources (*.article) — correct path is _content/blog/
rsync -a --include='*/' --include='*.article' --exclude='*' \
  "$SITE_DIR/_content/blog/" "$SITE_MD/blog/"

# --- language spec --------------------------------------------------------
printf "Fetching and converting Go language spec…\n"
mkp "$(dirname "$SPEC_MD")" "$(dirname "$SPEC_HTML")"
curl -fsSL https://raw.githubusercontent.com/golang/go/master/doc/go_spec.html -o "$SPEC_HTML"
pandoc -f html -t gfm -o "$SPEC_MD" "$SPEC_HTML"

# --- release notes --------------------------------------------------------
printf "Fetching and converting release notes…\n"
mkp "$REL_HTML_DIR" "$REL_MD_DIR"
curl -fsSL https://go.dev/doc/devel/release -o "$REL_HTML_DIR/release-history.html"
pandoc -f html -t gfm -o "$REL_MD_DIR/release-history.md" "$REL_HTML_DIR/release-history.html"
grep -oE '/doc/go1[^"]+' "$REL_HTML_DIR/release-history.html" | sort -u | while read -r path; do
  base="$(basename "$path")"
  curl -fsSL "https://go.dev${path}" -o "$REL_HTML_DIR/${base}.html"
  pandoc -f html -t gfm -o "$REL_MD_DIR/${base}.md" "$REL_HTML_DIR/${base}.html"
done

printf "Done.\n"
printf "API docs:           %s\n" "$PKG_MD_ROOT"
printf "Site docs (MD):     %s\n" "$SITE_MD"
printf "Release notes (MD): %s\n" "$REL_MD_DIR"
