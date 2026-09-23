#!/usr/bin/env bash

# Run a quick test of the loader / session start.
# Usage: ./run-loader-test.sh

cd "$(dirname "$0")"
exec emacs -Q --batch -l loader-live-test.el
