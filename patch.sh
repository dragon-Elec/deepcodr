#!/usr/bin/env bash
# deepcodr — patch script for DeepAI Code (t3code fork) Linux builds.
# Single source of truth: used identically by CI (GitHub Action) and locally.
#
# Fixes applied (both idempotent, marker-guarded):
#   FIX A — Node Happy-Eyeballs connect-attempt cutoff. Node's undici abandons
#           in-flight TCP connects after ~250ms per family; on links with RTT
#           above that (e.g. tethered ~300ms), every fetch to api.deepai.org
#           ETIMEDOUTs before connecting. Injects a 5000ms attempt timeout at
#           the top of every server/CLI entrypoint .mjs.
#   FIX B — OPTIONAL (opt-in only, never applied by CI): machineId detect()
#           has darwin/win32 branches only; Linux returns null and metered
#           calls may be answered with machine_required. Adds a Linux branch
#           reading /etc/machine-id (sha256-hashed, same treatment as the
#           other platforms). Account-specific: enabled by --machine-id.
#
# Usage: patch.sh <asar-out-dir> [--machine-id]
#   Modifies files in place inside <asar-out-dir>. Caller is responsible for
#   having extracted a pristine asar and for packing/verifying afterwards.
#   Exit 0 = applied (or already applied). Exit 1 = anchor missing / drift.

set -euo pipefail

MARKER_A='/* deepcodr:fixA net-autoselect-timeout */'
MARKER_B='/* deepcodr:fixB linux-machine-id */'

ASAR_OUT="${1:?usage: patch.sh <asar-out-dir> [--machine-id]}"
WANT_MACHINE_ID=0
[ "${2:-}" = "--machine-id" ] && WANT_MACHINE_ID=1

if [ ! -d "$ASAR_OUT" ]; then
	echo "FATAL: $ASAR_OUT is not a directory" >&2
	exit 1
fi

APPS_DIST="$ASAR_OUT/apps/server/dist"
[ -d "$APPS_DIST" ] || { echo "FATAL: layout drift: $APPS_DIST not found" >&2; exit 1; }

applied_a=0
skipped_a=0
applied_b=0
skipped_b=0

# ---------- FIX A: every entrypoint .mjs gets the net fix ----------
FIX_A_IMPORT='import { setDefaultAutoSelectFamilyAttemptTimeout } from "node:net";'
FIX_A_CALL='try { setDefaultAutoSelectFamilyAttemptTimeout(5000); } catch (e) { process.stderr.write("deepcodr: fixA failed: " + e + "\n"); }'

for entry in "$APPS_DIST"/bin.mjs "$APPS_DIST"/binCli-*.mjs; do
	[ -f "$entry" ] || continue
	if grep -qF "$MARKER_A" "$entry"; then
		skipped_a=$((skipped_a + 1))
		continue
	fi
	# Anchor: entry must be an ES module starting with import/export — protects
	# against silently prepending to some other file type by pattern accident.
	if ! head -c 4096 "$entry" | grep -qE '^(import|export) '; then
		echo "FATAL: anchor drift in $entry: not an ESM entry (no leading import/export)" >&2
		exit 1
	fi
	tmp="$entry.deepcodr.tmp"
	{
		echo "$MARKER_A"
		echo "$FIX_A_IMPORT"
		echo "$FIX_A_CALL"
		cat "$entry"
	} > "$tmp"
	node --check "$tmp" 2>/dev/null || { echo "FATAL: fixA made $entry unparseable" >&2; rm -f "$tmp"; exit 1; }
	mv "$tmp" "$entry"
	applied_a=$((applied_a + 1))
done

if [ $((applied_a + skipped_a)) -eq 0 ]; then
	echo "FATAL: no entrypoints found in $APPS_DIST (version drift?)" >&2
	exit 1
fi

# ---------- FIX B: optional Linux machine-id branch ----------
if [ "$WANT_MACHINE_ID" -eq 1 ]; then
	# Locate the detect() function by symbol anchor, not by hashed filename.
	target=""
	for f in "$APPS_DIST"/*.mjs; do
		[ -f "$f" ] || continue
		if grep -qF "$MARKER_B" "$f"; then
			target="$f"; skipped_b=1; break
		fi
		if grep -q 'async function detect() {' "$f" && grep -q 'NodeProcess.platform === "darwin"' "$f"; then
			target="$f"; break
		fi
	done
	if [ -z "$target" ]; then
		if [ "$skipped_b" -eq 1 ]; then
			echo "fixB: already applied"
		else
			echo "FATAL: fixB anchor not found: detect() symbol drifted (version bump?)" >&2
			exit 1
		fi
	else
		if [ "$skipped_b" -ne 1 ]; then
			# Insert a Linux branch before the bare "return null;" that ends detect().
			# Anchor context: the return null must be inside detect()'s body — the
			# darwin/win32 ifs above it are the confirmation we already matched.
			python3 - "$target" <<'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
marker = '/* deepcodr:fixB linux-machine-id */'
if marker in src:
    print("already"); sys.exit(0)
anchor = '\tif (NodeProcess.platform === "win32") return parseSmbiosUUID('
idx = src.find(anchor)
if idx < 0:
    print("FATAL: fixB win32-anchor not found", file=sys.stderr); sys.exit(1)
# find the bare "return null;" that terminates detect() after the win32 block
tail = src[idx:idx+2000]
m = re.search(r'\n\treturn null;\n', tail)
if not m:
    print("FATAL: fixB return-null anchor not found", file=sys.stderr); sys.exit(1)
inject_at = idx + m.start()
branch = (
    '\n\t' + marker + '\n'
    '\tif (NodeProcess.platform === "linux") {\n'
    '\t\ttry {\n'
    '\t\t\tconst fs = await import("node:fs/promises");\n'
    '\t\t\tconst raw = (await fs.readFile("/etc/machine-id", "utf8")).trim();\n'
    '\t\t\tif (raw) return raw;\n'
    '\t\t} catch (e) { process.stderr.write("deepcodr: fixB failed: " + e + "\\n"); }\n'
    '\t}\n'
)
out = src[:inject_at] + branch + src[inject_at:]
open(path, "w", encoding="utf-8").write(out)
print("patched")
PYEOF
			rc=$?
			if [ $rc -ne 0 ]; then
				echo "FATAL: fixB injection failed" >&2
				exit 1
			fi
			node --check "$target" || { echo "FATAL: fixB made $target unparseable" >&2; exit 1; }
			applied_b=1
		fi
	fi
fi

echo "patch summary: fixA applied=$applied_a skipped=$skipped_a | fixB applied=$applied_b skipped=$skipped_b requested=$WANT_MACHINE_ID"
exit 0
