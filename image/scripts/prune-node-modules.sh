#!/bin/sh
# NUCLEUS DELTA 6: strip developer-only content out of node_modules BEFORE the tree is
# snapshotted into prod_node_modules. Measured on the real image: -51.7 MB flat.
# Every deletion below was boot-tested (18 modules, 0 errors, Tyrion plugin, healthcheck,
# editor typings, Sparkplug encode/decode at runtime, serialport, classic-level, and a
# Manage Palette pure-JS install with a postinstall hook).
set -eu
ROOT="${1:-/usr/src/node-red/node_modules}"
cd "$ROOT"

# 1. protobufjs' code-generator CLI (pbjs/pbts + 52 nested packages). Runtime never
#    touches it: sparkplug-payload uses a pre-generated static module. -19.1 MB
rm -rf ./sparkplug-payload/node_modules/protobufjs/cli \
       ./sparkplug-payload/node_modules/protobufjs/bin \
       ./sparkplug-payload/node_modules/.bin/pbjs ./sparkplug-payload/node_modules/.bin/pbts \
       ./protobufjs/cli ./protobufjs/bin ./.bin/pbjs ./.bin/pbts 2>/dev/null || true

# 2. classic-level: the prebuilds are glibc binaries that segfault here (DELTA 4 compiled
#    a musl one into build/Release, which node-gyp-build prefers) and deps/ is leveldb
#    source. Deleting prebuilds also makes it impossible to ever load the wrong one. -5.8 MB
rm -rf ./classic-level/prebuilds ./classic-level/deps
test -f ./classic-level/build/Release/classic_level.node

# 3. Typings, source maps, markdown, tests, docs, examples. The editor serves Monaco
#    typings from @node-red/editor-client/public/types, so that tree is kept. -~45 MB
find . -type d -name '@types' -prune -exec rm -rf {} +
find . -type d \( -name test -o -name tests -o -name docs -o -name example \) -prune -exec rm -rf {} +
find . -path ./@node-red/editor-client/public/types -prune -o -type f \
     \( -name '*.d.ts' -o -name '*.map' -o -name '*.md' -o -name 'CHANGELOG*' \) -print0 | xargs -0 rm -f

# 4. node-gyp: the ROOT copy and its .bin links go (no compiler in the image), but the copy
#    nested inside the bundled npm STAYS - npm 11's run-script require.resolve()s
#    node-gyp/bin/node-gyp.js before EVERY lifecycle script, so deleting it breaks Manage
#    Palette for any pure-JS module with a postinstall (protobufjs, core-js, dashboard...).
rm -rf ./node-gyp ./.bin/node-gyp
test -f ./npm/node_modules/node-gyp/bin/node-gyp.js

# 5. Sanity: what the runtime needs must still be there.
test -d ./node-gyp-build
test -f ./@node-red/editor-client/public/types/node-red/func.d.ts
echo "prune-node-modules: done ($(du -sm . | cut -f1) MB left in node_modules)"
