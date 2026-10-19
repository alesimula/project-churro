#!/usr/bin/env bash
# system is mounted at /: its libraries are under system/lib64 (see patch-vendor.sh)
CHURRO_CRYPTO_SUB=system/ exec bash "$(dirname "$0")/patch-vendor.sh" "$@"
