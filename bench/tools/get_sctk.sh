#!/bin/bash
# Build NIST SCTK (sclite, rover) into bench/tools/sctk-src/bin, pinned to the
# commit the results here were scored with.
set -euo pipefail
cd "$(dirname "$0")"
REV=9688a26882a688132a5e414cadcb4c19b6fffaba
[ -d sctk-src ] || git clone -q https://github.com/usnistgov/SCTK.git sctk-src
cd sctk-src && git -c advice.detachedHead=false checkout -q "$REV"
make config >/dev/null && make all >/dev/null 2>&1 && make install >/dev/null
echo "sclite: $(pwd)/bin/sclite"
