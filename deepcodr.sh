#!/usr/bin/env bash
# deepcodr.sh — local driver for the DeepCodr patched DeepAI Code build.
#
# Model: the public GitHub release channel (deepcodr releases) is the source
# of patched artifacts. This script fetches from it, verifies, installs,
# launches with tripwires, and can patch locally for development/iteration.
#
# Commands:
#   deepcodr doctor              full state report + network probe
#   deepcodr fetch               download latest patched release (gh release)
#   deepcodr patch-local         extract pristine -> asar-out -> patch.sh [--machine-id]
#   deepcodr pack                build DeepAI-Code-<ver>-patched.AppImage from squashfs-root
#   deepcodr run [args...]       tripwire check -> launch patched artifact
#   deepcodr unpatch             remove patched state (pristine artifact untouched)
#
# Design rules (do not violate when editing):
#   - the pristine upstream AppImage is never modified (it is the unpatch path)
#   - every failure is loud; no silent successes (§2.5 of our spec)
#   - version provenance lives in state.json; run() refuses drifted state

set -euo pipefail

DC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WORK="${DEEPCODR_WORK:-$DC_DIR/work}"
STATE="$WORK/state.json"
UPSTREAM_APPIMAGE_GLOB="$DC_DIR/DeepAI-Code-*.AppImage"
REPO="${DEEPCODR_REPO:-}"   # set by fetch from gh, or owner/name env

log()  { printf '[deepcodr] %s\n' "$*"; }
warn() { printf '[deepcodr] WARN: %s\n' "$*" >&2; }
die()  { printf '[deepcodr] FATAL: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

check_deps() {
	need curl; need unsquashfs; need mksquashfs; need node; need npx; need python3
	need jq
}

# ---------------- state helpers ----------------

write_state() {
	# $1 = key, $2 = value  (flat json, jq-managed)
	local key="$1" val="$2"
	mkdir -p "$WORK"
	if [ -f "$STATE" ]; then
		jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
	else
		jq -n --arg k "$key" --arg v "$val" '{[$k]: $v}' > "$STATE"
	fi
}

state_get() {
	[ -f "$STATE" ] || { echo ""; return; }
	jq -r --arg k "$1" '.[$k] // empty' "$STATE" 2>/dev/null || echo ""
}

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true; }

# ---------------- doctor ----------------

cmd_doctor() {
	check_deps
	log "== deepcodr doctor =="

	log "-- artifacts --"
	local found=0
	for f in $UPSTREAM_APPIMAGE_GLOB; do
		[ -e "$f" ] || continue
		log "  pristine artifact: $f"
		log "    sha256: $(sha "$f")"
		found=1
	done
	[ "$found" -eq 1 ] || warn "no pristine DeepAI-Code AppImage found in $DC_DIR"

	if [ -d "$WORK/squashfs-root" ]; then
		log "  extracted tree:   $WORK/squashfs-root (present)"
		if [ -L "$WORK/squashfs-root/resources/app" ]; then
			log "  patch symlink:    resources/app -> $(readlink "$WORK/squashfs-root/resources/app")"
		else
			log "  patch symlink:    (absent — unpatched extraction)"
		fi
	else
		log "  extracted tree:   (none)"
	fi

	log "-- state --"
	if [ -f "$STATE" ]; then
		jq . "$STATE"
		local src_sha state_sha
		src_sha="$(state_get source_sha256)"
		state_sha="$(sha "$(state_get source_artifact 2>/dev/null || echo /nonexistent)")"
		if [ -n "$src_sha" ] && [ "$src_sha" != "$state_sha" ]; then
			warn "PROVENANCE DRIFT: pristine artifact changed since last sync/patch"
			warn "  state says: $src_sha"
			warn "  now:        $state_sha"
		fi
	else
		log "  (no state — never patched here)"
	fi

	log "-- network probe (Happy-Eyeballs diagnosis) --"
	probe_network

	log "-- upstream channel --"
	check_upstream_version || warn "could not reach upstream latest-linux.yml"
}

probe_network() {
	# Reproduce the exact failure signature: bare-node fetch vs curl.
	# Node dying ~1s while curl succeeds == the Happy-Eyeballs cutoff bug.
	local curl_rc=0 node_rc=0
	curl -fsS -o /dev/null -m 10 https://api.deepai.org/deepai_code/models 2>/dev/null || curl_rc=$?
	node -e '
const t = Date.now();
fetch("https://api.deepai.org/deepai_code/models", { signal: AbortSignal.timeout(8000) })
	.then(r => { console.log("node-fetch: " + r.status + " in " + (Date.now()-t) + "ms"); process.exit(0); })
	.catch(e => { console.log("node-fetch FAILED after " + (Date.now()-t) + "ms: " + (e.cause?.code || e.name)); process.exit(1); });
' 2>/dev/null || node_rc=$?
	if [ $curl_rc -eq 0 ] && [ $node_rc -ne 0 ]; then
		warn "signature confirmed: curl OK but node fetch fails — Happy-Eyeballs bug present, patch REQUIRED"
	elif [ $curl_rc -eq 0 ] && [ $node_rc -eq 0 ]; then
		log "node fetch OK — network healthy for bare Node (patch may be unnecessary here, but harmless)"
	else
		warn "curl also failing (rc=$curl_rc) — network problem beyond the Node bug; fix connectivity first"
	fi
}

check_upstream_version() {
	local yml
	yml="$(curl -fsSL -m 15 https://downloads.deepai.org/deepai-code/releases/latest-linux.yml 2>/dev/null)" || return 1
	local ver
	ver="$(printf '%s' "$yml" | grep -oP '(?<=^version: )[0-9.]+' | head -1)"
	[ -n "$ver" ] || return 1
	log "  upstream latest: $ver (url: $(printf '%s' "$yml" | grep -oP '(?<=url: ).+' | head -1))"
	state_get patched_version >/dev/null || true
	local pv
	pv="$(state_get patched_version)"
	if [ -n "$pv" ] && [ "$pv" != "$ver" ]; then
		warn "upstream $ver > patched $pv — run: $0 fetch (or wait for CI release)"
	fi
	return 0
}

# ---------------- fetch (from our public release channel) ----------------

cmd_fetch() {
	check_deps
	need gh
	[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
	[ -n "$REPO" ] || die "cannot determine release repo: run inside the deepcodr repo or set DEEPCODR_REPO=owner/name"
	log "fetching latest patched release from $REPO"
	mkdir -p "$WORK"
	local dl="$WORK/release-download"
	rm -rf "$dl"; mkdir -p "$dl"
	gh release download -R "$REPO" -p "DeepAI-Code-*-patched.AppImage" -p "latest-linux.yml" -O "$dl/" --clobber \
		|| die "gh release download failed (auth? repo has releases?)"
	log "downloaded:"
	ls -la "$dl"
	log "verify manifest vs file:"
	local want got
	want="$(grep -oP '(?<=sha512: ).+' "$dl/latest-linux.yml" | head -1 | base64 -d 2>/dev/null | xxd -p -c 128 | head -c 128)"
	got="$(sha512sum "$dl"/DeepAI-Code-*-patched.AppImage | cut -d' ' -f1)"
	if [ "${#want}" = "128" ] && [ "$want" = "$got" ]; then
		log "  sha512 MATCH ($got)"
	else
		die "sha512 MISMATCH: manifest=$want file=$got — refusing install"
	fi
	# install: replace work artifact
	local inst="$WORK/DeepAI-Code-patched.AppImage"
	mv "$dl"/DeepAI-Code-*-patched.AppImage "$inst"
	write_state installed_artifact "$inst"
	write_state installed_sha256 "$got"
	write_state installed_at "$(date -Iseconds)"
	log "installed: $inst"
	log "launch with: $0 run"
}

# ---------------- patch-local (dev path) ----------------

cmd_patch_local() {
	check_deps
	local machine_id_flag=""
	[ "${1:-}" = "--machine-id" ] && machine_id_flag="--machine-id"

	local pristine
	pristine="$(ls -t $UPSTREAM_APPIMAGE_GLOB 2>/dev/null | head -1)"
	[ -n "$pristine" ] && [ -e "$pristine" ] || die "no pristine AppImage found in $DC_DIR"

	mkdir -p "$WORK"
	local sfs="$WORK/squashfs-root"

	if [ ! -d "$sfs" ]; then
		log "extracting AppImage filesystem..."
		unsquashfs -q -d "$sfs" "$pristine" >/dev/null
	fi

	local asar="$sfs/resources/app.asar"
	local out="$sfs/resources/asar-out"
	if [ ! -d "$out" ]; then
		log "extracting asar (pristine copy kept)..."
		npx --yes @electron/asar extract "$asar" "$out"
		# CRITICAL: asar extract does NOT materialize .unpacked native modules.
		if [ -d "$sfs/resources/app.asar.unpacked" ]; then
			cp -a "$sfs/resources/app.asar.unpacked/." "$out/"
			log "merged app.asar.unpacked native modules into asar-out"
		fi
	fi

	log "applying patches (fixA mandatory, fixB ${machine_id_flag:-off})..."
	"$DC_DIR/patch.sh" "$out" $machine_id_flag

	# The patch: one symlink. Electron loads resources/app/ over app.asar.
	if [ ! -L "$sfs/resources/app" ]; then
		ln -s asar-out "$sfs/resources/app"
		log "patch symlink created: resources/app -> asar-out"
	fi

	write_state source_artifact "$(readlink -f "$pristine")"
	write_state source_sha256 "$(sha "$pristine")"
	write_state patched_at "$(date -Iseconds)"
	write_state machine_id "$([ -n "$machine_id_flag" ] && echo on || echo off)"
	write_state patch_mode "local-symlink"

	log "== patched. launch test: $0 run =="
}

# ---------------- run (tripwired launch) ----------------

cmd_run() {
	local sfs="$WORK/squashfs-root"
	[ -d "$sfs" ] || die "no patched tree — run: $0 fetch (release channel) or $0 patch-local (dev)"

	# tripwire 1: patch symlink present?
	if [ ! -L "$sfs/resources/app" ]; then
		die "patch symlink missing in $sfs — tree is unpatched. re-run: $0 patch-local"
	fi
	# tripwire 2: markers still present (someone re-extracted over us?)
	local marker_file
	marker_file="$(grep -rlF '/* deepcodr:fixA' "$sfs/resources/app/apps/server/dist/" 2>/dev/null | head -1)"
	[ -n "$marker_file" ] || die "patch markers not found — patched tree is stale/broken. re-run: $0 patch-local"
	# tripwire 3: provenance drift
	local src_sha now_sha src_path
	src_sha="$(state_get source_sha256)"
	src_path="$(state_get source_artifact)"
	if [ -n "$src_sha" ] && [ -n "$src_path" ] && [ -e "$src_path" ]; then
		now_sha="$(sha "$src_path")"
		if [ "$src_sha" != "$now_sha" ]; then
			die "upstream artifact changed (auto-update swapped it) — patched tree may be stale. run: $0 patch-local (or $0 fetch)"
		fi
	fi
	# tripwire 4: fetch-installed artifact preferred if present
	local inst
	inst="$(state_get installed_artifact)"
	if [ -n "$inst" ] && [ -e "$inst" ]; then
		log "launching installed patched release: $inst"
		chmod +x "$inst"
		exec "$inst" "$@"
	fi

	log "launching patched tree: $sfs/AppRun"
	exec "$sfs/AppRun" "$@"
}

# ---------------- pack (portable artifact; used by CI and locally) ----------------

cmd_pack() {
	check_deps
	local sfs="$WORK/squashfs-root"
	[ -d "$sfs" ] || die "no squashfs-root to pack — run patch-local first"

	# 1. pack asar from asar-out -> patched.asar
	log "packing asar..."
	npx --yes @electron/asar pack "$sfs/resources/asar-out" "$WORK/patched.asar"

	# 2. build staging AppDir: replace app.asar with patched, drop asar-out symlink
	local stage="$WORK/appdir"
	rm -rf "$stage"; cp -a "$sfs" "$stage"
	rm -f "$stage/resources/app"
	cp "$WORK/patched.asar" "$stage/resources/app.asar"
	rm -rf "$stage/resources/app.asar.unpacked" "$stage/resources/asar-out"
	# native modules referenced by asar must sit beside it
	if [ -d "$sfs/resources/asar-out/node_modules" ]; then
		# asar.pack already folded unpacked files via asar's unpacked dir rules;
		# regenerate the unpacked dir from asar-out for safety
		mkdir -p "$stage/resources/app.asar.unpacked"
	fi

	# 3. squashfs
	local sq="$WORK/deepai-code-patched.squashfs"
	rm -f "$sq"
	mksquashfs "$stage" "$sq" -all-root -noappend -no-progress -comp gzip >/dev/null

	# 4. concat original ELF runtime stub + new squashfs = valid AppImage
	local pristine
	pristine="$(ls -t $UPSTREAM_APPIMAGE_GLOB 2>/dev/null | head -1)"
	[ -n "$pristine" ] || die "no pristine AppImage to harvest runtime stub from"
	local stub="$WORK/runtime-stub.bin"
	rm -f "$stub"
	# find the squashfs offset inside the pristine AppImage (ELF stub prefix)
	local offset
	offset="$(python3 - "$pristine" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read(4 * 1024 * 1024)
# AppImage magic at offset 8: "AI\x02" for type 2
sq = b"hsqs"
i = data.find(sq)
print(i if i > 0 else -1)
PYEOF
)"
	[ "$offset" -gt 0 ] || die "could not locate squashfs offset in pristine AppImage"
	dd if="$pristine" of="$stub" bs=4M count=1 2>/dev/null
	truncate -s "$offset" "$stub"
	log "runtime stub harvested: $offset bytes"

	local out="$WORK/DeepAI-Code-patched.AppImage"
	rm -f "$out"
	cat "$stub" "$sq" > "$out"
	chmod +x "$out"
	log "built: $out ($(du -h "$out" | cut -f1))"

	# 5. verify: it must run --appimage-extract cleanly and contain our marker
	local verify="$WORK/.verify.$$"
	rm -rf "$verify"
	"$out" --appimage-extract >/dev/null 2>&1 || die "built AppImage fails --appimage-extract"
	grep -rlF '/* deepcodr:fixA' "$verify/squashfs-root/resources/app.asar" >/dev/null 2>&1 \
		|| die "verification failed: fixA marker not visible in packed asar"
	rm -rf "$verify"
	log "verification passed: marker present in packed artifact"
}

# ---------------- unpatch ----------------

cmd_unpatch() {
	local sfs="$WORK/squashfs-root"
	if [ -L "$sfs/resources/app" ]; then
		rm "$sfs/resources/app"
		log "patch symlink removed — tree is unpatched (app.asar was never touched)"
	else
		log "nothing to unpatch (no symlink)"
	fi
	[ -f "$STATE" ] && { rm -f "$STATE"; log "state cleared"; }
	log "pristine AppImage untouched throughout — that is the unpatch path."
}

case "${1:-help}" in
	doctor)      cmd_doctor ;;
	fetch)       cmd_fetch ;;
	patch-local) shift || true; cmd_patch_local "$@" ;;
	pack)        cmd_pack ;;
	run)         shift || true; cmd_run "$@" ;;
	unpatch)     cmd_unpatch ;;
	*) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
