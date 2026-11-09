# DeepCodr

Patched builds of **DeepAI Code for Linux** (a t3code/Cursor-fork white-label), with the fix for the login-breaking Node network bug upstream ships on every build.

## The bug (why this exists)

DeepAI Code's Node backend dies at login on connections with RTT above ~250ms (tethered mobile links, some VPNs):

- Node's undici (fetch) abandons in-flight TCP connections after ~250ms per address family (Happy-Eyeballs `autoSelectFamilyAttemptTimeout` default)
- On such links every `fetch("https://api.deepai.org/...")` throws `ETIMEDOUT` in ~1s, *after* the OS had almost completed the connect
- `curl` on the same machine succeeds — the endpoint is fine; only Node's fetch dies
- Result: sign-in callback is received but the token exchange fails → "Could not reach DeepAI to finish signing in"

A second, smaller gap: `machineId detect()` has darwin/win32 branches only — on Linux no `X-DeepAI-Code-Machine` header is sent and metered calls may be answered with `machine_required`. That fix is **opt-in** (see below).

## What this repo does

A GitHub Action (every 6h) checks `downloads.deepai.org` for a new Linux build. When one appears:

1. downloads it, sha512-verifies against the upstream manifest
2. extracts, applies **patch.sh** (single source of truth — CI and local use the same file)
3. verifies: every modified entrypoint must parse (`node --check`), markers present, boot smoke must pass
4. repacks (asar → squashfs → concat with the **original** runtime stub)
5. **flips `app-update.yml` to this repo** — so the installed patched copy self-updates from *these* patched releases and can never be silently replaced by an unpatched upstream build
6. publishes a release tagged `deepai-v<version>`

## Install (as a user)

```sh
gh release download -R <you>/deepcodr -p "DeepAI-Code-*-patched.AppImage"
chmod +x DeepAI-Code-*-patched.AppImage
./DeepAI-Code-*-patched.AppImage
```

The patched copy then keeps itself up to date (it checks *this* repo's releases, not DeepAI's).

## Local development / iteration

`deepcodr.sh` is the local driver:

```sh
./deepcodr.sh doctor        # state + network probe (reproduces the bug signature live)
./deepcodr.sh patch-local   # extract pristine AppImage → apply patches → symlink
./deepcodr.sh run           # tripwired launch of the patched tree
./deepcodr.sh pack          # build a portable patched AppImage locally
./deepcodr.sh unpatch       # remove patch (pristine AppImage is never modified)
```

### Optional: machine-id fix (fixB)

Only enable if you see `machine_required` errors on metered calls:

```sh
./deepcodr.sh patch-local --machine-id
```

This sends a persistent hardware identifier (sha256 of `/etc/machine-id`) with every metered request. It is deliberately **not** applied in CI builds.

## Design rules

- The pristine upstream AppImage is never modified — it is the unpatch path and the update source of truth
- Patches are marker-guarded and idempotent; anchors are code symbols, never hashed filenames
- Every gate failure is loud (no silent successes)
- Provenance (source sha, patch manifest, gate results) is recorded in release notes

## License note

The patch scripts in this repo are MIT. DeepAI Code's binary itself is redistributed via releases built from upstream's own published artifacts — see the upstream project (t3code, MIT) for its terms.
