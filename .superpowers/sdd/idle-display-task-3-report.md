# Idle Display Task 3 报告

## 状态

已完成空闲展示设置的持久化、片段尺寸展示倍率接口、片段库设置控件与错误展示 hook。Core resolver 与测试已单独提交；按安全覆盖规则，应用层两个既有脏文件保持未暂存。

## 实现

- `IdlePresentationPolicy.resolvedManicScale(_:)`：缺失值使用 `2.0`，非有限值回退默认值，有效值限制在 `1.0...3.0`。
- `LibraryState`：新增 `preventIdleDisplaySleep`、`manicIdleDelay`、`manicScale`；`.empty` 使用安全默认值；Codable 增加对应 key。
- 旧 JSON 兼容：`manicIdleDelay` 使用 `container.contains(.manicIdleDelay)` 区分字段缺失与显式 `null`。缺失时恢复默认 5 分钟，显式 `null` 保持关闭。
- `PetClip.effectiveDisplaySize`：新增默认值为 `1` 的 `presentationMultiplier`，仅在正常猫素材调用方显式传入时放大；现有鼠标互动目标调用保持默认倍率，不受影响。倍率非有限或小于 `1` 时安全回退/限制为 `1`。
- `LibraryWindowController`：新增“阻止自动锁屏与关闭屏幕”复选框、空闲展示固定选项（关闭、1/3/5/10/15/30 分钟）、`1...3` 倍率滑块与数值标签。
- 下拉项的 `representedObject` 使用秒数 `NSNumber`，关闭项使用 `NSNull`。修改时统一持久化并发送 `.libraryDidChange`。
- `reload` 精确匹配 represented seconds，恢复复选框、下拉框、倍率和标签；关闭空闲展示时仅禁用倍率滑块，不覆盖已保存倍率。
- 新增 `presentIdleDisplaySleepError(_:)`：窗口可见时显示 sheet，否则 modal 显示。

## RED / GREEN

1. RED：先添加 `testPersistedManicScaleUsesSafeDefaultAndBounds`，运行指定过滤测试。编译按预期失败：`IdlePresentationPolicy` 没有 `resolvedManicScale` 成员。
2. GREEN：加入最小 resolver 后重跑同一测试，执行 1 条、0 失败。
3. 策略回归：`swift test --filter IdlePresentationPolicyTests`，执行 4 条、0 失败。
4. 完整回归：`swift test`，执行 73 条、0 失败。
5. 编译：`swift build` 成功，无新增编译错误或警告。

说明：沙箱内首次执行 SwiftPM 被模块缓存/嵌套 sandbox 权限阻止；改为获准的沙箱外执行后，取得上述真实 RED/GREEN 和验证结果。

## 文件与提交

已提交（仅 core/test）：

- `Sources/DesktopPetCore/IdlePresentationPolicy.swift`
- `Tests/DesktopPetTests/IdlePresentationPolicyTests.swift`
- commit：`27567dc`（`[设置] 保存空闲展示选项并增加控制项`）

保持未暂存：

- `Sources/DesktopPet/Models.swift`
- `Sources/DesktopPet/LibraryWindowController.swift`
- 本报告文件

应用层文件相对任务前快照核对后，只增加本任务所需 hunk；未撤销、重排或覆盖已有鼠标互动、素材分类和单片段缩放改动。

## Self-review

- 固定延迟选项与 `IdlePresentationPolicy.supportedIdleDelays` 一致，默认值为 300 秒。
- 缺失字段和显式 `null` 的语义已明确区分；倍率缺失、非有限值和越界值均通过 resolver 安全处理。
- 关闭功能不会丢失倍率值，重新开启后可恢复。
- 现有 `effectiveDisplaySize(globalScale:)` 调用保持源码兼容，鼠标互动目标尺寸不会被展示倍率意外放大。
- staged diff 已执行 `git diff --cached --check`，提交中只包含允许的两个文件。
- 未做 AppKit 运行时视觉截图验证；布局已通过编译，设置容器高度由 150 增至 184，但最终视觉密度仍建议主任务集成后手动打开片段库确认。

## Concerns

无阻塞问题。唯一剩余风险是 AppKit 设置行尚未做真实窗口视觉验收；逻辑与编译验证均已通过。

---

## 审查修复：显式持久化关闭状态

### 问题确认

审查指出的问题成立：原实现把 `manicIdleDelay` 直接声明为可选存储属性，Swift 合成的 `Encodable` 会在值为 `nil` 时省略该键；再次解码时，缺失键按旧 JSON 兼容规则回退为 300 秒，因此用户选择“关闭”后重启会被错误恢复为开启。

### 修复实现

- 在 `DesktopPetCore` 新增非可选 `PersistedIdleDelay: Codable` wrapper。
- wrapper 的 `value` 仍为 `TimeInterval?`，但 `encode(to:)` 使用 single-value container；`nil` 明确执行 `encodeNil()`。
- `LibraryState` 内部改为非可选 `manicIdleDelayStorage: PersistedIdleDelay`，通过 `CodingKeys` 将 storage 映射到原 JSON 键 `manicIdleDelay`。
- 对外继续提供 `var manicIdleDelay: TimeInterval?` 计算属性，因此控制器和其他调用点 API 不变。
- 自定义 decode 继续使用 `contains`：缺键经 policy 恢复 300 秒；键存在且为 `null` 时 wrapper 解为 `nil`；不支持的秒数仍由 policy 回退 300 秒。
- 未手写整个 `LibraryState.encode(to:)`，避免未来新增或现有用户字段被遗漏。

### 自动化测试与 RED / GREEN

先新增 JSON 测试，再写 wrapper：

1. `swift test --filter IdlePresentationPolicyTests`
   - RED：退出码 1；3 个新增测试按预期因 `PersistedIdleDelay` 不存在而编译失败。
2. 加入最小 wrapper 后再次运行 `swift test --filter IdlePresentationPolicyTests`
   - GREEN：执行 7 tests，0 failures。
3. 加强测试为外层 Codable fixture 后再次运行同一命令
   - 执行 7 tests，0 failures。
   - 覆盖：显式 `null` 解码为 `nil`；编码后 `manicIdleDelay` 键存在且值为 `NSNull`；编码后解码仍保持关闭。
   - 原 `testSupportedDelaysAndLegacyDefaultAreExact` 继续覆盖缺失字段默认 300 秒。
4. `swift build`
   - 成功，`Build complete!`，无编译错误。
5. `swift test`
   - 执行 76 tests，0 failures，退出码 0。

### 提交与未提交边界

- 新提交：`3f04347`（`[设置] 保留关闭的空闲展示延迟`）
- 提交仅包含：
  - `Sources/DesktopPetCore/IdlePresentationPolicy.swift`
  - `Tests/DesktopPetTests/IdlePresentationPolicyTests.swift`
- `git diff --cached --check` 通过；提交前索引只列出上述两个文件。
- `Sources/DesktopPet/Models.swift` 的 storage 接入修复保持未暂存、未提交。
- `Sources/DesktopPet/LibraryWindowController.swift` 与本报告保持未暂存、未提交。

### Self-review

- 非可选 wrapper 确保合成 encode 无法省略 `manicIdleDelay` 键。
- 外层 fixture 使用与 `LibraryState` 相同的 storage/CodingKeys 结构，自动化验证了关键合成 Codable 行为。
- 缺键与显式 null 仍有不同语义，未破坏旧 JSON 默认 300 秒的兼容路径。
- 对外 `manicIdleDelay` 类型和读写方式不变，现有 UI action/reload 无需调整。
- 无新的阻塞 concern；AppKit 设置行的视觉验收风险与前述报告一致。
