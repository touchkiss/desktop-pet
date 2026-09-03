# Repository Guidelines

## Project Structure & Module Organization

This is a Swift Package Manager project targeting macOS 13 and later. Application code lives in `Sources/DesktopPet/`; window controllers, playback, chroma-key processing, and teleport renderers are separated by responsibility. Reusable, UI-independent teleport types and calculations belong in `Sources/DesktopPetCore/`. Add unit tests under `Tests/DesktopPetTests/`, mirroring the production type where practical (for example, `TeleportMathTests.swift`). Design notes and implementation plans are stored in `docs/superpowers/`. Generated outputs such as `.build/` and `DesktopPet.app/` must remain untracked.

## Build, Test, and Development Commands

- `swift build` compiles a debug build for local development.
- `swift run DesktopPet` builds and launches the executable directly.
- `swift test` runs the complete XCTest suite.
- `swift test --filter TeleportMathTests` runs one test class while iterating.
- `./build_app.sh` creates a release build and packages it as `DesktopPet.app`.
- `open DesktopPet.app` launches the packaged menu-bar application.

Video import requires `ffmpeg` on `PATH` (`brew install ffmpeg`).

## Coding Style & Naming Conventions

Follow established Swift style: four-space indentation, one primary type per file, `UpperCamelCase` for types, and `lowerCamelCase` for methods, properties, and enum cases. Name controllers and renderers by role (`PomodoroController`, `TileSwarmRenderer`). Keep AppKit-specific behavior in `DesktopPet`; move deterministic geometry and timing logic into `DesktopPetCore` so it remains testable. No formatter or linter is configured, so match surrounding code and keep compiler warnings at zero.

## Testing Guidelines

Tests use XCTest and `@testable import DesktopPetCore`. Name test methods `test<Behavior>` and cover boundary values, clamping, deterministic random inputs, and fallback paths. Every change to core calculations should add or update focused tests. Run `swift test` before submitting a change; no numeric coverage threshold is currently enforced.

## Commit & Pull Request Guidelines

Recent commits use concise bracketed categories in Chinese, such as `[项目配置] 新增项目配置文件和忽略文件`. Follow that pattern when appropriate: `[范围] 动词 + 变更摘要`, and keep each commit focused. Pull requests should explain user-visible behavior, implementation scope, and validation performed. Link related issues or design documents, and include screenshots or a short recording for visual, animation, window, or menu changes. Note any macOS-version or `ffmpeg` assumptions.
