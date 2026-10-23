#!/bin/zsh
set -eu
exec /usr/bin/python3 "${0:A:h}/build_update.py" --retry-upload
