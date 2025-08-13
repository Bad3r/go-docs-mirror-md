# SPDX-License-Identifier: AGPL-3.0-or-later
# File.: go-docs-mirror-md / Makefile
# Desc.: Convenience targets for syncing a local Markdown mirror of Go docs.

SHELL := /usr/bin/env bash

# ---- Config ----
ROOT         ?= $(PWD)                                 # matches script default
SCRATCH      ?= $(ROOT)/_tmp
SCRIPT       ?= ./go-docs-sync.sh
QUIET        := $(if $(findstring s,$(MAKEFLAGS)),1,0) # respect Make's -s/--silent flag

# Generated trees (align with script)
API_MD_DIR   ?= $(ROOT)/docs
SITE_DIR     ?= $(ROOT)/_site_src
SITE_MD      ?= $(ROOT)/site-md
REL_MD_DIR   ?= $(ROOT)/release-notes/md

# Blog conversion (copied to $(SITE_MD)/blog/)
BLOG_SRC_DIR ?= $(SITE_MD)/blog
BLOG_MD_DIR  ?= $(SITE_MD)/blog-md

# “All” API docs (incl. unexported, built by sync-u)
ALL_DIR      ?= $(ROOT)/all

# Parallelism hint for optional loops
CONCURRENCY  ?= $(or $(shell nproc 2>/dev/null),$(shell sysctl -n hw.ncpu 2>/dev/null),4)

.PHONY: help sync sync-u blog-md check clean clean-api deep-clean print-config

help:
	@printf "Targets:\n"
	@printf "  make sync         - Run the full sync (API docs -> %s, site docs, release notes)\n" "$(API_MD_DIR)"
	@printf "  make sync-u       - Sync including a second API tree w/ UNEXPORTED symbols -> %s\n" "$(ALL_DIR)"
	@printf "  make blog-md      - Convert blog .article sources to Markdown (keeps sources)\n"
	@printf "  make check        - Verify required tools are installed\n"
	@printf "  make clean        - Remove temporary files only (\\n    %s)\n" "$(SCRATCH)"
	@printf "  make clean-api    - Remove generated API docs only (\\n    %s)\n" "$(API_MD_DIR)"
	@printf "  make deep-clean   - Remove temp + generated content (docs, site-md, release-notes, clone, all)\n"
	@printf "  make print-config - Show effective variables\n"

print-config:
	@printf "ROOT=%s\n" "$(ROOT)"
	@printf "SCRATCH=%s\n" "$(SCRATCH)"
	@printf "API_MD_DIR=%s\n" "$(API_MD_DIR)"
	@printf "SITE_DIR=%s\n" "$(SITE_DIR)"
	@printf "SITE_MD=%s\n" "$(SITE_MD)"
	@printf "REL_MD_DIR=%s\n" "$(REL_MD_DIR)"
	@printf "BLOG_SRC_DIR=%s\n" "$(BLOG_SRC_DIR)"
	@printf "BLOG_MD_DIR=%s\n" "$(BLOG_MD_DIR)"
	@printf "ALL_DIR=%s\n" "$(ALL_DIR)"
	@printf "CONCURRENCY=%s\n" "$(CONCURRENCY)"

check:
	@missing=0; \
	if [ "$(QUIET)" != "1" ]; then printf "Checking required tools:\n"; fi; \
	for c in go git curl pandoc rsync xargs grep find sort wc; do \
	  if command -v $$c >/dev/null 2>&1; then \
	    if [ "$(QUIET)" != "1" ]; then printf "  ✔ %s\n" "$$c"; fi; \
	  else \
	    printf "Missing: %s\n" "$$c"; missing=1; \
	  fi; \
	done; \
	if [ $$missing -eq 0 ]; then \
	  if [ "$(QUIET)" != "1" ]; then printf "All good.\n"; fi; \
	else \
	  printf "Fix the missing tools above and re-run.\n"; exit 1; \
	fi

sync: check
	@printf ">> Syncing docs into %s ...\n" "$(ROOT)"
	@$(SCRIPT) "$(ROOT)"

# Build a *second* API tree that includes unexported symbols, without touching the main mirror.
# Output goes under $(ALL_DIR)/<import path>/README.md
sync-u: sync
	@printf ">> Generating API docs with UNEXPORTED symbols into %s ...\n" "$(ALL_DIR)"
	@mkdir -p "$(SCRATCH)" "$(ALL_DIR)"
	@go list -f '{{if or (gt (len .GoFiles) 0) (gt (len .CgoFiles) 0)}}{{.ImportPath}}{{end}}' std cmd \
	 | sed '/^$$/d' | sort -u > "$(SCRATCH)/packages.txt"
	@cat "$(SCRATCH)/packages.txt" | xargs -P "$(CONCURRENCY)" -I {} sh -c \
	  'mkdir -p "$(ALL_DIR)/{}"; gomarkdoc -u --output "$(ALL_DIR)/{{.ImportPath}}/README.md" {}'
	@printf ">> Done (unexported API mirror): %s\n" "$(ALL_DIR)"

# Convert blog .article files to Markdown alongside the sources.
# Produces: $(BLOG_MD_DIR)/**.md with minimal front matter (title, published)
blog-md: sync
	@printf ">> Converting blog .article -> Markdown ...\n"
	@mkdir -p "$(BLOG_MD_DIR)" "$(SCRATCH)"
	@find "$(BLOG_SRC_DIR)" -type f -name '*.article' -print0 | \
	while IFS= read -r -d '' f; do \
	  rel="$${f#$(BLOG_SRC_DIR)/}"; \
	  out="$(BLOG_MD_DIR)/$${rel%.article}.md"; \
	  mkdir -p "$$(dirname "$$out")"; \
	  title="$$(grep -m1 '^Title:' "$$f" | sed 's/^Title:[[:space:]]*//')"; \
	  published="$$(grep -m1 '^Published:' "$$f" | sed 's/^Published:[[:space:]]*//')"; \
	  printf -- '---\n' > "$$out"; \
	  [ -n "$$title" ] && printf 'title: "%s"\n' "$$title" >> "$$out"; \
	  [ -n "$$published" ] && printf 'published: "%s"\n' "$$published" >> "$$out"; \
	  printf -- '---\n\n' >> "$$out"; \
	  awk 'BEGIN{h=1} { if(h && $$0==""){h=0; next} if(!h) print }' "$$f" > "$(SCRATCH)/.blog-body.html"; \
	  pandoc -f html -t gfm -o "$(SCRATCH)/.blog-body.md" "$(SCRATCH)/.blog-body.html"; \
	  cat "$(SCRATCH)/.blog-body.md" >> "$$out"; \
	done
	@printf ">> Blog Markdown written under %s\n" "$(BLOG_MD_DIR)"

clean:
	@printf ">> Cleaning temp: %s\n" "$(SCRATCH)"
	@rm -rf "$(SCRATCH)"

clean-api:
	@printf ">> Removing API docs: %s\n" "$(API_MD_DIR)"
	@rm -rf "$(API_MD_DIR)"

deep-clean: clean
	@printf ">> Removing generated trees: %s %s %s %s %s\n" "$(API_MD_DIR)" "$(SITE_DIR)" "$(SITE_MD)" "$(REL_MD_DIR)" "$(ALL_DIR)"
	@rm -rf "$(API_MD_DIR)" "$(SITE_DIR)" "$(SITE_MD)" "$(REL_MD_DIR)" "$(ALL_DIR)"
