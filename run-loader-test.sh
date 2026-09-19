#!/usr/bin/env bash

# Run a quick test of the loader / session start.
# Usage: ./run-loader-test.sh

# Ensure the correct load‑path for `acp` and our package.
EMACSLOADPATH="/home/khalid/.emacs.d/elpa/acp-20260906.1056:/home/khalid/agent-org"

emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/home/khalid/.emacs.d/elpa/acp-20260906.1056\")" \
  --eval "(add-to-list 'load-path \"/home/khalid/agent-org\")" \
  -l loader-live-test.el
