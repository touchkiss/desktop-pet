# Task 1：空闲展示纯逻辑策略报告

## 结果

已新增 `IdlePresentationPhase` 与 `IdlePresentationPolicy`，实现支持的空闲延迟、旧配置解析、魔性倍率边界裁剪、阶段判定和展示倍率。实现只依赖 Foundation，不接触 AppKit/IOKit 或应用层类型。

## RED 证据

先新增 `Tests/DesktopPetTests/IdlePresentationPolicyTests.swift`，运行 `swift test --filter IdlePresentationPolicyTests`。首次沙箱内运行因 SwiftPM 无法访问编译器 ModuleCache 而失败；按工具规则以所需权限重跑后，确认测试在编译阶段失败，核心错误为 `cannot find 'IdlePresentationPolicy' in scope`，并同时报告阶段枚举成员无法解析。该失败符合“类型尚不存在”的预期 RED。

## GREEN 证据

- `swift test --filter IdlePresentationPolicyTests`：3 tests passed，0 failures。
- `swift test`：69 tests passed，0 failures。

## 文件

- `Sources/DesktopPetCore/IdlePresentationPolicy.swift`
- `Tests/DesktopPetTests/IdlePresentationPolicyTests.swift`

## Self-review

- 对照简报逐项核验了公开类型、方法签名、常量数值和边界行为；实现与给定最小实现一致。
- 测试覆盖支持延迟列表及旧配置默认/无效值、阈值与无效空闲时间、倍率 NaN/上下界及阶段倍率。
- 未修改已有脏文件或其他任务文件；暂存和提交前将只包含上述两个任务文件。
