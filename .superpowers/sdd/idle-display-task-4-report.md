# Idle Display Task 4 报告

## 状态

已完成魔性展示倍率在猫窗口与传送落点几何中的接入。实现保持单一最终尺寸来源，阶段切换即时刷新，窗口按底边中心重算并以完整含 padding 的尺寸钳制到当前屏幕可见区域。

按控制器下发的安全覆盖规则，本任务未执行 `git add` 或 `git commit`；所有修改均保留在工作树中。

## 实现

- `PetClipPresentationPolicy.displaySize` 新增默认值为 `1` 的 `presentationMultiplier` 参数。
- 正常片段倍率、全局倍率和展示倍率的最终乘法统一在 Core `displaySize` 中完成；展示倍率非有限时回退 `1`，小于 `1` 时限制为 `1`。
- `PetClip.effectiveDisplaySize` 改为直接委托 Core API，不再对返回尺寸二次乘法。
- `PetWindowController` 新增 `idlePresentationPhase`，默认 `.normal`；`setIdlePresentationPhase(_:)` 仅在阶段变化时更新状态并立即调用 `refreshFrame()`。
- `PetWindowController.effectiveDisplaySize(for:)` 统一结合当前全局缩放、保存的魔性倍率和当前展示阶段，供普通窗口刷新与传送落点共用。
- `refreshFrame()` 保持现有底边中心锚点，以 `内容尺寸 + effectPadding * 2` 重算完整窗口尺寸，再使用 `(window.screen ?? NSScreen.main)?.visibleFrame` 和 `TeleportMath.clampOrigin` 钳制完整窗口。
- `TeleportController.placeLandingFrame()` 改用 `pet.effectiveDisplaySize(for:)`，不再直接从模型按普通倍率计算。
- cursor-prey overlay 仍使用自身 `CursorPreySettings.displaySize` 路径，未接入猫窗口的展示阶段倍率。

## RED / GREEN

1. RED：先添加 `testDisplaySizeAppliesPresentationMultiplierAfterNormalScale`，未修改生产代码。
2. 首次沙箱内运行精确测试被 SwiftPM 模块缓存权限阻止，未作为有效 RED 证据。
3. 获准在沙箱外运行：
   - `swift test --filter PetClipPresentationPolicyTests/testDisplaySizeAppliesPresentationMultiplierAfterNormalScale`
   - 退出码 `1`，按预期编译失败：`extra argument 'presentationMultiplier' in call`。
4. GREEN：加入最小 Core API 与应用层委托后重跑同一命令：执行 1 条测试，0 失败。
5. 聚焦回归：`swift test --filter PetClipPresentationPolicyTests`，执行 10 条测试，0 失败。

## 完整验证

- `swift test`：执行 77 条 XCTest，0 失败，退出码 0。
- `swift build`：`Build complete!`，退出码 0。
- `git diff --check -- <5 个任务文件>`：通过，无空白错误。
- 与 `.superpowers/sdd/idle-display-task-4-before/` 的逐文件快照比较：只有本任务所需 hunk；未撤销或覆盖既有鼠标互动、传送、帧加载防御与单片段缩放代码。

## 文件

- `Sources/DesktopPetCore/PetClipPresentationPolicy.swift`
- `Tests/DesktopPetTests/PetClipPresentationPolicyTests.swift`
- `Sources/DesktopPet/Models.swift`
- `Sources/DesktopPet/PetWindowController.swift`
- `Sources/DesktopPet/TeleportController.swift`
- `.superpowers/sdd/idle-display-task-4-report.md`

上述改动均未暂存、未提交。

## Self-review

- 最终尺寸乘法只有 Core `PetClipPresentationPolicy.displaySize` 一个来源；模型层仅透传参数。
- 普通 `refreshFrame()` 与传送 `placeLandingFrame()` 均通过 `PetWindowController.effectiveDisplaySize(for:)` 获取展示尺寸。
- `.normal` 阶段倍率固定为 `1`；`.manic` 阶段使用已由 policy 安全限制的保存倍率。
- 阶段没有变化时 setter 不触发多余刷新；发生变化时同步刷新。
- 窗口重算先保存旧底边与中心点，再调整完整 padded frame，最后钳制，避免放大后越出当前屏幕可见区域。
- `freezeFrameForTeleport` 的既有所有权语义保持不变：刷新仍更新图片及内容尺寸，但传送中不抢夺窗口几何。
- cursor-prey overlay 代码及其独立尺寸设置未改动。
- 未执行任何暂存或提交操作。

## Concerns

无阻塞问题。AppKit 窗口锚点、跨屏钳制和传送动画尚未做真实 UI 动画录屏验收；本任务已通过纯计算测试、完整 XCTest 和应用构建，集成阶段仍建议手动观察一次正常/魔性阶段切换及传送落地视觉。
