# Task Group 1: Interaction Policy and Data Model

Implement OpenSpec tasks 1.1–1.5 for `add-cursor-prey-interaction`.

## Requirements

- Add `Tests/DesktopPetTests/CursorInteractionPolicyTests.swift` first and verify RED before production code.
- Cover exact size bounds 16 and 128 pt, out-of-range clamping, default 48 pt, and interaction eligibility only for an autonomous `.cursorNudge` with both prey and cat-interaction candidates available.
- Add `Sources/DesktopPetCore/CursorInteractionPolicy.swift` with the minimal public size constants, clamp function, and eligibility API needed by the tests.
- Add `ClipTag.cursorPrey`, `ClipTag.cursorInteraction`, and optional Codable `CursorPreySettings` to `PetClip`. Old JSON without the new field must decode as ordinary material with nil settings.
- Add LibraryStore APIs for mutually exclusive cursor-prey/cursor-interaction roles and per-clip prey size updates. First enabling prey creates 48 pt settings. Disabling prey preserves the last settings.
- Exclude either special tag from `LibraryState.playableClips`, active queue resolution, and `TransitionMatcher.rebuildAutoLinks`. Preserve the order of remaining ordinary clips and do not affect `petting`.
- Keep macOS 13 and Swift 5.9 compatibility. Add no dependency.

## Ownership

- Create/modify only:
  - `Tests/DesktopPetTests/CursorInteractionPolicyTests.swift`
  - `Sources/DesktopPetCore/CursorInteractionPolicy.swift`
  - `Sources/DesktopPet/Models.swift`
  - `Sources/DesktopPet/LibraryStore.swift`
  - `Sources/DesktopPet/ChromaKeyProcessor.swift`
- Do not edit `README.md`, `.DS_Store`, `AGENTS.md`, OpenSpec artifacts, UI, playback engine, or teleport files.
- Do not commit. The checkout is dirty and contains user-owned changes.

## Verification

1. Run the new filtered test before implementation and record the expected failure.
2. Run `swift test --filter CursorInteractionPolicyTests` after implementation.
3. Run full `swift test`.
4. Review the diff for scope and compatibility.

Write the complete report to `.superpowers/sdd/cursor-prey-task-1-report.md`, including RED/GREEN commands and results, files changed, self-review, and concerns. Return only DONE, a one-line test summary, and any concerns.
