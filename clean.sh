#!/usr/bin/env bash
find . -maxdepth 1 -type d ! -name . -print0 | xargs -0 -r rm -rf
