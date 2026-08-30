# Tiger Team state

## Mission
Native macOS port of virt-viewer/remote-viewer on branch `mac-port`, to be
opened as an upstream PR. Done = (1) documented Homebrew build, (2)
`build-aux/macos/make-bundle.sh` produces a relocatable, ad-hoc-signed
`Remote Viewer.app` that launches, (3) `spice://`/`vnc://` URLs and `.vv`
files open the app, (4) macOS menu bar / Cmd shortcuts / bundle-relative
resources work, (5) GitHub Actions macOS CI green, (6) all changes
platform-guarded so Linux/Windows are untouched.

## Configuration notes
- Branch: `mac-port` (root checkout). Single-branch mode: accepts merge here.
  Never touch `master`.
- test_cmd = `bash build-aux/macos/check.sh` (meson setup+ninja+meson test in
  `build/`). The tree built and tested clean on macOS before any port work.
- Fleet: codex (gpt-5.6-sol, C3, frontier), grok (C3), ds (pi/DeepSeek, C2),
  opus (claude login, C3, frontier+macbuild, **unsandboxed** per user 2026-08-30).
  Seatbelt for all others (`~/.tigerteam.toml`).
- Homebrew deps installed by the PM on 2026-08-30 (see AGENTS.md list).

## Decision log (append-only)
- 2026-08-30 — Mac port = packaging + integration; no compile fixes needed
  (verified: meson/ninja/4 tests green with brew deps) — scope tickets accordingly.
- 2026-08-30 — Platform guard is `__APPLE__` / meson `darwin`; ObjC only when
  CoreFoundation can't do it — keep the upstream PR reviewable.
- 2026-08-30 — oVirt and bash-completion stay disabled on macOS (no brew formula).
- 2026-08-30 — GUI verification only on the unsandboxed `opus` lane
  (`capability: [macbuild]`).
- 2026-08-30 — CI via GitHub Actions `macos-latest` (upstream GitLab has no
  mac runners); workflow lives in `.github/workflows/`.

## Board snapshot
- 2026-08-30 14:05 — board created; T-0001..T-0009 in todo/; Seatbelt build+test verified green; fleet released (`tigerteam up` was already running), events --wait armed.

## Next actions
- Review landings oldest-first; after T-0002 + T-0005 land, promote QA T-0009.

## How to resume
1. Read this file. 2. `tigerteam status`. 3. review/ then blocked/.
4. `git worktree list`. 5. `tigerteam up`; re-arm events. 6. Next actions.
