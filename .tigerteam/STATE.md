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

- 2026-08-30 — worker.sb: added `file-read-metadata` on `$HOME/b` (ROOT's
  ancestor). Without it git in a Seatbelt worker fails with `Invalid path
  '/Users/d/b'` — upstream skill profile assumes the repo sits directly under
  $HOME. Killed grok/ds attempts (no penalty) so they relaunch under the fix.
- 2026-08-30 — arm64 hosts skip the stack-protector probe (aarch64 guard);
  ticket criteria must not require it in the meson log.

- 2026-08-30 — Operator raised lane scale (codex 2, grok 2, ds 3, opus 2).
  Side effect seen: the pre-rename `opus` runner kept its T-0005 attempt while
  `opus-1/2` showed idle — harmless, but scale edits mid-attempt confuse the
  dashboard.
- 2026-08-30 — T-0005 reworked (attempt 2): startup `Gtk-CRITICAL
  gtk_window_add_accel_group` from the unparented off-screen GtkMenuBar;
  pinned to `assignee: opus` (unsandboxed) so the fix is verified on a display.
- 2026-08-30 — TCC: this PM session cannot `screencapture` (no Screen
  Recording grant). User granted Terminal.app Screen Recording and is
  restarting Terminal + PM session; T-0009 screenshots depend on the
  supervisor's terminal having that grant.
- 2026-08-30 — docs/macos.md is created independently by several tickets
  (T-0001, T-0003, T-0005…); accept conflicts are resolved by keeping the
  full doc and appending the new section. Expect the same for T-0002/T-0005.

## Board snapshot
- 2026-08-30 14:15 — done: T-0001, T-0003. doing: T-0002 (grok). todo: T-0005
  (rework, opus), T-0004 (waits T-0002), T-0006/7/8/9 (deps). Merges landed on
  `mac-port`: 353ea74 (T-0001), f9f1243 (T-0003).
- 2026-08-30 14:05 — board created; T-0001..T-0009 in todo/; Seatbelt build+test verified green; fleet released (`tigerteam up` was already running), events --wait armed.

## Next actions
- After the Terminal restart: `tigerteam status`; check the supervisor is alive
  (`tigerteam check`), else `tigerteam up`; arm `tigerteam events --wait`.
- **T-0002 is in review/ now** (grok, landed 14:16 — unreviewed). Review it first (expect docs/macos.md conflict → append section;
  meson.build touches near T-0005's block).
- Review T-0005 attempt 2: require the pasted fatal-criticals run.
- When T-0002 + T-0005 are done, T-0004 and T-0007 become eligible automatically.
- Review landings oldest-first; after T-0002 + T-0005 land, promote QA T-0009.

## How to resume
1. Read this file. 2. `tigerteam status`. 3. review/ then blocked/.
4. `git worktree list`. 5. `tigerteam up`; re-arm events. 6. Next actions.
