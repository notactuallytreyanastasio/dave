#!/usr/bin/env bash
# Build the GitHub Pages site (docs/): the bundle, then the page.
#
# The bundle is the library's own JavaScript translation,
# bundled for the browser as one file exposing `window.Dave`.
#
#   scripts/site.sh            # writes docs/dave.js
#
# Needs a JavaScript build (bin/temper build -b js) and esbuild. Jam Pilot's
# checkout has one at ../notedance_viewer/_build/esbuild-*; set ESBUILD to
# use another. The page itself is docs/index.html; publish both.
set -euo pipefail
cd "$(dirname "$0")/.."
out=temper.out/js
[ -d "$out/dave" ] || bin/temper build -b js
esbuild=${ESBUILD:-$(ls ../notedance_viewer/_build/esbuild-* 2>/dev/null | head -1)}
[ -n "$esbuild" ] || { echo "no esbuild; set ESBUILD" >&2; exit 1; }
entry=$(mktemp -d)/entry.js
cat > "$entry" <<'JS'
import * as chat from "dave/chat";
import * as rounds from "dave/rounds";
import * as agent from "dave/agent";
import * as room from "dave/room";
import * as repair from "dave/repair";
import * as compose from "dave/compose";
import * as dave from "dave";
import { parseJson } from "@temperlang/std/json";
export { chat, rounds, agent, room, repair, compose, dave, parseJson };
JS
# esbuild resolves alias targets against the working directory; the entry
# file is copied under it so the resolver finds the aliased packages.
cp "$entry" build/site.entry.js 2>/dev/null || { mkdir -p build; cp "$entry" build/site.entry.js; }
"$esbuild" build/site.entry.js --bundle --format=iife --global-name=Dave --minify --outfile=docs/dave.js \
  --alias:@temperlang/core=./$out/temper-core --alias:@temperlang/std=./$out/std --alias:dave=./$out/dave \
  --log-override:duplicate-object-key=silent 2>&1 | grep -vE 'pair\.js|getter|^\s*$|key\(|value\(|\^|~|warning' || true
ls -la docs/dave.js
python3 scripts/site/build.py
