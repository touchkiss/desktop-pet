# SDD Progress Ledger — random teleport effects

Repo has no git; work in-place without commits. Reviews use file snapshots/diffs.

Task 1: complete (no commits, review clean). Minors: unused CoreGraphics import (needed in Task 2); jitter boundary tests optional; pickStyle bucket edges.
Task 2: complete (no commits, review clean after Important fixes). Minors: cornerRegions doc wording; multi-screen best init.
Task 3: complete (no commits, review clean). Minors: no automated LibraryState decode test; frequency not clamped on decode.
Task 4: complete (no commits, review clean). Minors: dense row3; empty messages allowed.
Task 5: complete (no commits, review clean). Minors: mouseDown vs drag; persist helper duplication.
Task 6: complete (no commits, review clean after cancel() fix). Minors: host===onPet contract; particleImage cache.
Task 7: complete (no commits, review Approved). TeleportController state machine.
Task 8: complete (no commits). AppDelegate wired; quit calls stop(); build+13 tests pass.

All plan tasks done. Manual QA checklist remains for the user.

## add-cursor-prey-interaction

Baseline: `swift test` passed 28 tests, 0 failures on 2026-08-27. User approved working directly on `main`; no task commits because the checkout contains unrelated user changes.
Task group 1 (OpenSpec 1.1–1.5): complete (no commits, review clean). Tests: 32 passed. Minor: direct regression tests for app-layer Codable/store/filter behavior remain desirable.
Task group 2 (OpenSpec 2.1–2.4): complete (no commits, review clean after two fix rounds). Tests: 32 passed; debug build passed. Review fixes covered queue semantics, empty ordinary playback, preview close lifecycle, and post-correction refresh.
Task group 3 (OpenSpec 3.1–3.4): complete (no commits, review clean after generation-token fix). Tests: 38 passed; debug build passed. One-shot completion is exactly-once and reentrancy-safe, including same-ID replacement.
Task group 4 (OpenSpec 4.1–4.4): complete (no commits, review clean after single-driver/window-health fix). Tests: 43 passed; debug build passed. Manual cursor/multi-display QA remains in task group 6.
### add-cursor-prey-interaction · Group 5

- Completed tasks 5.1–5.6: autonomous-only orchestration, distinct random pairing, shared landing startup, one-shot restoration, and idempotent cleanup across interruptions.
- Closed the synchronous playback-observer cancellation window with revision/state revalidation and pending-session cancellation handling.
- Verification: `swift test` passed 51/51; independent re-review found no Critical, Important, or Minor issues.

### add-cursor-prey-interaction · Final verification

- Added immediate cancellation and ordinary-frame redraw when an interaction cat PNG cannot be decoded, including first-frame TOCTOU and same-ID single-frame restoration.
- Preserved the normal reminder fallback for abnormal interaction startup/render failures.
- Verification: `swift test` passed 53/53, `./build_app.sh` succeeded, OpenSpec strict validation passed, and final independent review found no Critical or Important issues.
- Manual tasks 6.3–6.4 remain pending because the current 77-clip library contains no cursor-prey/action materials and no multi-display test environment is available.

## idle-display-and-manic-scale

Baseline: `swift test` passed 66 tests, 0 failures on 2026-09-02. User explicitly required working directly on the current `main` branch; preserve unrelated uncommitted changes and stage only feature hunks.
Task 1: complete (commit `c15e543`, review clean). Added idle-delay, phase, and manic-scale policy; 69 tests passed.
Task 2: complete (commit `d12dfa8`, review clean). Added idempotent display-sleep lease with acquire/release failure coverage; 72 tests passed.
Task 3: complete (commits `27567dc`, `3f04347`; application hunks intentionally uncommitted; review clean after persistence fix). Explicit JSON null round-trip preserves disabled state; 76 tests passed. Minor: AppKit row still needs visual QA.
Task 4: complete (no commit to protect pre-existing dirty/untracked files; snapshot review clean). Window and teleport share one stage-aware size source; 77 tests and build passed. Manual cross-screen/animation QA remains.
Task 5: complete (commit `aa63242`; AppDelegate hunk intentionally uncommitted; review approved). IOKit display assertion, HID idle sampling, failure fallback, and termination cleanup integrated; 77 tests and build passed. Minor: settings changes can cause redundant refreshes.
Task 6: complete (README hunk intentionally uncommitted; review clean). Fresh verification: 77 tests passed, debug build passed, release app packaging passed, diff check clean. macOS GUI/power/manual-lock checks remain explicitly unexecuted.
Final review: approved after two fix rounds. Fixed any-input HID sentinel, deferred geometry refresh after teleport freeze, dedicated idle settings notification preserving engine hold, invalid-size geometry guards, accurate UI/docs, and immediate persistence-error feedback. Independent final assessment: Ready to merge, no Critical/Important; app-layer/real-system manual QA remains.
