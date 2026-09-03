# Cursor-prey task 1 report

## TDD evidence

### RED

Command:

```sh
swift test --filter CursorInteractionPolicyTests
```

The initial sandboxed invocation could not create Xcode's module cache. Re-running
the same command with the required compiler-cache permission reached compilation
and failed as intended: `CursorInteractionPolicy` was not in scope in the new
test file. This verified that the tests required the missing production API.

### GREEN

Command:

```sh
swift test --filter CursorInteractionPolicyTests
```

Result: passed — 4 tests, 0 failures. The tests cover inclusive 16/128 pt
bounds, clamping outside that range, the 48 pt default, and require an
autonomous `.cursorNudge` landing plus both candidate types.

### Full suite

Command:

```sh
swift test
```

Result: passed — 32 tests, 0 failures.

## Changed files

- `Tests/DesktopPetTests/CursorInteractionPolicyTests.swift`
- `Sources/DesktopPetCore/CursorInteractionPolicy.swift`
- `Sources/DesktopPet/Models.swift`
- `Sources/DesktopPet/LibraryStore.swift`
- `Sources/DesktopPet/ChromaKeyProcessor.swift`

## Implementation summary

- Added the public, deterministic cursor-interaction policy and size constants.
- Added the two special tags and optional `CursorPreySettings`; missing settings
  decode as `nil`, and stored/assigned sizes are constrained to 16...128 pt.
- Added mutually exclusive store role APIs and per-clip prey size updates. First
  prey enable creates the 48 pt configuration; disabling retains it.
- Filtered special materials from normal playback/queue resolution and automatic
  transition-link candidates without altering the saved active queue.

## Self-review

- `git diff --check` passed for the five owned implementation/test files.
- Existing `petting` tags are untouched.
- Transition rebuild clears links for special clips and only scores ordinary
  clips, including when the ordinary set has fewer than two clips.
- No unowned files were edited and no commit was made.

## Concerns

None. The first test invocation needed compiler-cache permission because the
workspace sandbox blocks Xcode's user cache; all recorded test results above are
from the permitted standard SwiftPM invocation.
