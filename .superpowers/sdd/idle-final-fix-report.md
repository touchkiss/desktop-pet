# 空闲显示保护与魔性放大最终集中修复报告

日期：2026-09-02
范围：最终审查中的 A–F 阻断项；未执行 `git add`、`git commit`、GUI 启动、锁屏或系统休眠设置变更。

## 结论

已完成代码侧阻断修复：HID 查询使用 any-input sentinel；传送冻结期间的几何更新会在 padding 清理并解冻后补刷；idle 设置走专用通知并保留播放 hold；异常内容、padded 和 landing 尺寸不会写入窗口；UI 文案与 README 边界已校正。

自动验证结果：聚焦回归 23 项、完整 XCTest 83 项均为 0 failures；`swift build` 和 `./build_app.sh` 退出码均为 0；`git diff --check` 退出码 0。系统级电源、真实输入、锁屏和视觉行为仍需人工验收，不能由本报告宣称通过。

## Root cause → fix

### A. 总体 HID 空闲时间查询错误

**根因（已确认）**：原实现把 `.null`（raw value 0）传给 `CGEventSource.secondsSinceLastEventType`。SDK 对总体键盘、鼠标和数位板空闲查询要求 `kCGAnyInputEventType`，即 `~0` / `UInt32.max`。

**修复**：

- `Sources/DesktopPetCore/IdlePresentationPolicy.swift:30-38` 新增可注入的 `HIDIdleTimeQuery`，固定把 `UInt32.max` 传给查询闭包。
- `Sources/DesktopPet/AppDelegate.swift:210-217` 把 raw sentinel 转换为 `CGEventType` 后调用 CoreGraphics，继续使用 `.hidSystemState`。
- 未使用 `DeclareUserActivity`、`caffeinate`、子进程或模拟输入；静态搜索这些入口无命中。

### B. 传送 freeze 解冻后遗漏最终几何

**根因（已确认）**：`refreshFrame()` 在 freeze 内更新内容尺寸但跳过 window frame；原 `finishTrip()` 只清 Bool。单帧 key 不再变化时，阶段或片段尺寸变化可永久残留旧 frame。

**修复**：

- 新增 `Sources/DesktopPetCore/DeferredGeometryRefreshState.swift`：`beginFreeze → requestRefresh → endFreeze`，冻结请求合并为一次最终刷新。
- `Sources/DesktopPet/PetWindowController.swift:215-225,391-419` 集中管理 freeze；冻结中只记录 dirty，解冻时重新从素材尺寸计算，不把倍率叠加到旧 frame。
- `Sources/DesktopPet/TeleportController.swift:222,641` 改用 begin/end API。出现特效既有顺序是 padding 清零后 completion，再进入 `finishTrip()`，因此最终 refresh 使用零 padding。
- `restorePetPresentation()` 只在 end 未补刷时主动刷新，避免同一路径重复刷新。

### C. idle 设置通过通用库通知破坏播放 hold

**根因（已确认）**：idle checkbox、延迟或倍率原来发送 `.libraryDidChange`，随后 `AppDelegate.handleLibraryChange()` 的有效片段分支调用 `engine.restartTimer()`，清除 `holdingAtEnd`、`pendingNextID` 和 ending-soon 状态；`TeleportController.holdingEngine` 不同步。

**修复**：

- `Sources/DesktopPet/LibraryWindowController.swift:1005-1014` 改发专用 `.idlePresentationSettingsDidChange`。
- `Sources/DesktopPet/AppDelegate.swift:104-112,192-195` 的专用 handler 只同步 IOKit assertion、重新评估 phase，并刷新 scale；不调用任何 PlaylistEngine reset API。
- 阶段未变化时使用 `forceRefresh` 刷新一次，保证同阶段修改魔性倍率立即生效；阶段变化时由 `setIdlePresentationPhase` 刷新，避免同一次设置重复刷新。
- assertion 创建失败后把持久化设置回退为 `false`、reload 控件并展示错误，不再广播 `.libraryDidChange`，所以不会在失败回退中破坏 hold。
- 通用 `.libraryDidChange` 仍保留原有播放重调度语义；本修复只隔离 idle 设置，避免扩大行为范围。

### D. 非正/非有限尺寸可污染 window geometry

**根因（已确认）**：Core 原来分别把非正宽高压为 0，可能产生 `(0, h)` 或 `(w, 0)`；普通刷新会先写 `petDisplaySize`/content size，再写 window frame。landing 只检查 `> 0`，`infinity` 仍可通过。

**修复**：

- `Sources/DesktopPetCore/PetClipPresentationPolicy.swift:78-100` 对任一非正源维度返回 `.zero`，并提供有限且正数的统一 validator；最终计算结果同样经过 validator。
- `Sources/DesktopPet/PetWindowController.swift:399-419` 在修改 `petDisplaySize`、`contentView.petContentSize` 或 window frame 前，同时校验内容尺寸、padded 尺寸和最终 frame。
- `setTeleportLandingFrame()` 校验 size、center、clamp 后 origin；`setTeleportEffectPadding()` 在保存 padding 或写 frame 前校验 prospective frame。
- 失败时保留旧几何，清除不可呈现图像并复用 `onFrameLoadFailed` 素材失败路径，不生成零维、负数、NaN 或 infinity frame。

### E/F. 文案、文档与测试边界

- UI 已统一为“空闲后放大”“魔性倍率”。
- README 明确 assertion 同时阻止系统 idle sleep；真实输入后“通常在下一次采样、约 1 秒内恢复”。
- 未拆分 `LibraryState` 到 Core，也未复制模型来伪造真实 Codable 测试。真实 `LibraryState` CodingKeys/旧 JSON/round-trip 直接 XCTest 仍是非阻塞缺口。

## 严格 RED → GREEN 证据

### A. HID sentinel / adapter

1. RED：
   - 命令：`swift test --filter IdlePresentationPolicyTests/testHIDIdleTimeQueryUsesAnyInputEventSentinel`
   - 退出码：1
   - 关键输出：`cannot find 'HIDIdleTimeQuery' in scope`。
2. GREEN：
   - 同一命令最终退出码：0。
   - 关键输出：执行 1 项，0 failures。
3. SDK 适配诊断：`swift -e 'import CoreGraphics; print(CGEventType(rawValue: UInt32.max) as Any)'` 输出 `Optional(__C.CGEventType)`；据此显式安全解包，而不是假设初始化非 Optional。
4. 首次 GREEN 接线编译分别暴露“CGEventType? 未解包”和闭包缺少显式 `return`，修正后才取得上述通过结果；未把编译失败误报为 GREEN。

### B. deferred geometry state

1. RED：
   - 命令：`swift test --filter DeferredGeometryRefreshStateTests`
   - 退出码：1
   - 关键输出：`cannot find 'DeferredGeometryRefreshState' in scope`。
2. GREEN：
   - 同一命令退出码：0。
   - 关键输出：执行 3 项，0 failures。
3. 覆盖：未冻结时立即 refresh、冻结请求在 end 时触发一次、多次请求合并一次。

### D. 无效尺寸

1. RED：
   - 命令：`swift test --filter PetClipPresentationPolicyTests/testDisplaySizeReturnsZeroWhenEitherSourceDimensionIsNonPositive`
   - 退出码：1。
   - 关键输出：4 个预期失败，原实现分别返回 `(0, 50)`、`(100, 0)`、`(0, 50)`、`(100, 0)`，而不是 `.zero`。
2. GREEN：
   - 同一命令退出码：0。
   - 关键输出：执行 1 项，0 failures。
3. validator RED：
   - 命令：`swift test --filter PetClipPresentationPolicyTests/testDisplaySizeValidityRequiresFinitePositiveDimensions`
   - 退出码：1。
   - 关键输出：`PetClipPresentationPolicy has no member 'isValidDisplaySize'`。
4. validator GREEN：
   - 同一命令最终退出码：0，执行 1 项，0 failures。
   - 中间一次因 `.nan`/`.infinity` 在 `CGFloat` 与 `Double` 间歧义而未编译；测试改为显式 `CGFloat.nan`/`CGFloat.infinity` 后取得 GREEN。

说明：第一次在沙箱内运行 Swift 命令时，Clang ModuleCache 因权限退出 1，未进入测试。后续获准使用用户级编译缓存后才执行上述真实 RED/GREEN；环境失败未计作 RED。

## 变更文件

- `Sources/DesktopPet/AppDelegate.swift`
- `Sources/DesktopPet/PetWindowController.swift`
- `Sources/DesktopPet/TeleportController.swift`
- `Sources/DesktopPet/LibraryWindowController.swift`
- `Sources/DesktopPetCore/IdlePresentationPolicy.swift`
- `Sources/DesktopPetCore/DeferredGeometryRefreshState.swift`（新建）
- `Sources/DesktopPetCore/PetClipPresentationPolicy.swift`
- `Tests/DesktopPetTests/IdlePresentationPolicyTests.swift`
- `Tests/DesktopPetTests/DeferredGeometryRefreshStateTests.swift`（新建）
- `Tests/DesktopPetTests/PetClipPresentationPolicyTests.swift`
- `README.md`

未改 `Package.swift`、IOKit adapter、`Models.swift` 或 `PlaylistEngine.swift`；未撤销鼠标互动、传送、素材库等已有脏改动。

## 最终自动验证

| 命令 | 结果 |
|---|---|
| `swift test --filter 'IdlePresentationPolicyTests|DeferredGeometryRefreshStateTests|PetClipPresentationPolicyTests'` | 退出码 0；23 项，0 failures |
| `swift test` | 退出码 0；83 项，0 failures（0 unexpected） |
| `swift build` | 退出码 0；`Build complete! (0.48秒)` |
| `./build_app.sh` | 退出码 0；production build 完成，生成 `DesktopPet.app` |
| `git check-ignore -v DesktopPet.app` | 退出码 0；命中 `.gitignore:2:DesktopPet.app/` |
| `git diff --check` | 退出码 0；无输出 |
| `git diff --cached --name-only` | 退出码 0；无输出，暂存区为空 |
| 禁止 API 静态搜索 | `DeclareUserActivity`、`caffeinate`、`CGEventPost`、`IOPMSet` 均无命中 |

## Self-review 与风险评估

- 完成后另派独立只读 reviewer 对照修复前快照与 A–F 要求复核；评分 97/100，结论为 Ready to merge，未发现 Critical、Important 或 Minor 问题。reviewer 未重跑会写 `.build` 的命令，测试与构建证据仍以本报告实际执行结果为准。
- 逐文件与控制器保存的 `.superpowers/sdd/idle-final-fix-before/` 快照比较，仅出现本报告列出的集中修复；`Models.swift` 无差异。
- HID adapter 锁定 raw sentinel 并保留 `.hidSystemState`；真实 CoreGraphics API 行为仍需实际键鼠输入验证。
- geometry dirty 在 freeze 期间会被帧刷新持续置位，但只在 end 消费一次。多数传送会因此在结束时做一次同尺寸幂等 refresh；不会重复乘倍率，但需人工观察特效交界是否存在可见跳动。
- 专用 idle 通知不再触碰播放引擎。其他非 idle 的通用库变更仍可能调用 `restartTimer()`；这是本修复范围外的既有语义。
- 无效几何会保留旧 frame/content size，但清空当前不可呈现图像；one-shot 可走现有失败恢复，普通损坏素材会保持安全空白直到后续有效片段。
- AppKit window、IOKit assertion 和真实 `LibraryState` 不在当前 Core-only test target 中。若为直接 XCTest 强行拆大模块，会超过本次最小修复范围，因此保持为显式测试缺口。

## 未执行的人工验收

为避免改变主机状态，本次没有运行 `open DesktopPet.app`、没有锁屏、合盖、主动睡眠、修改系统显示休眠时间或等待真实阈值。以下均未声称通过：

1. assertion 开关实际阻止显示器和系统 idle sleep，关闭后恢复系统行为。
2. `Control-Command-Q`、系统菜单锁屏、合盖和主动睡眠不被阻止。
3. 真实鼠标与键盘输入在通常下一次采样、约 1 秒内恢复 normal。
4. 单帧片段在 appear 期间 normal↔manic 双向切换，结束后尺寸、底边中心和 visible-frame clamp 正确。
5. hold 中修改 checkbox、delay、scale 后，pending next、cursor interaction 与 one-shot 连续。
6. `0×N`、`N×0`、负尺寸或非有限最终尺寸在真实窗口中保留旧几何并安全回退。
7. 多屏边缘、3.0× 倍率、各传送风格与 padding 组合的视觉验收。

这些项目需要操作者在愿意改变本机显示/锁屏状态并可观察 UI 的环境中完成。

## 追加修复：设置保存失败的即时、准确反馈

最终复审在 A–F 关闭后发现一个新的 Important：`LibraryStore.save/update` 写盘失败只写入通用 `lastError`；idle 设置改走专用通知后不会触发 reload，导致错误不能即时展示，而未来 reload 又会把任意 `lastError` 固定显示成“导入失败”。运行时设置看似成功，重启后却可能回滚。

### Root cause → fix

- `Sources/DesktopPet/LibraryStore.swift:114-138`
  - `save()` 与 `update(_:)` 改为 `@discardableResult -> String?`，同步返回本次保存错误；所有已有调用仍可忽略返回值，保持源代码兼容。
  - 保存成功返回 `nil`，不清除旧 `lastError`；失败只在原先没有错误时把本次错误写入 `lastError`，避免覆盖与本次无关的旧错误。
  - 新增 `consumeLastError(ifMatching:)`；调用方只按本次返回值清理，且用 `previousLastError == nil` 证明该槽位确由本次保存占用，避免同文旧错误被误清。
- `Sources/DesktopPet/LibraryWindowController.swift:999-1069`
  - `idlePresentationSettingsChanged()` 同步接收 `store.update` 的本次结果。失败时立即以准确标题“保存设置失败”提示：“本次运行中已生效，但未写入磁盘，重启后可能恢复旧值”。
  - 无论保存成功或失败，均继续发送专用 `.idlePresentationSettingsDidChange`；没有发送 `.libraryDidChange`，也没有接触 engine、`restartTimer()` 或 hold。
  - 保存错误被当场消费，不会在后续 reload 中再次以“导入失败”误报。
  - 保存错误和显示休眠 assertion 错误共用按顺序展示、按完整标题/正文去重的队列；两类错误不会因同时请求 sheet 而互相覆盖。
- `Sources/DesktopPet/AppDelegate.swift:197-214`
  - IOKit assertion 失败后的设置回退也同步接收保存结果；若回退本身未写盘，会进入同一准确保存错误队列，再独立排队展示 assertion 错误。
  - 用 focused `refreshIdlePresentationControls()` 更新 checkbox，不触发全量 reload，也不消费无关错误。
- `docs/superpowers/specs/2026-09-02-idle-display-and-manic-scale-design.md:84-92`
  - 已移除“广播现有 library change”的过期描述，明确专用 idle notification 不进入播放重调度。
  - 已补充保存失败仍在当前进程生效、继续发送专用通知、即时提示磁盘未写入及重启回滚风险。

### 追加验证

当前 test target 只依赖 `DesktopPetCore`，不能直接 import `LibraryStore`、`LibraryState` 或 AppKit controller。本次按约束没有写读取 Swift 源码文本的伪测试，也没有为此拆分 app target；真实 `LibraryState`/保存错误 UI 集成测试继续保留为 Minor 测试缺口。

代码最终定稿后重新执行的证据：

| 命令 | 确切结果 |
|---|---|
| `swift test` | 退出码 0；83 项 XCTest，0 failures（0 unexpected）；`Build complete! (4.06秒)` |
| `swift build` | 退出码 0；`Build complete! (0.20秒)` |
| `./build_app.sh` | 退出码 0；production build 完成（11.05 秒），生成被忽略的 `DesktopPet.app` |
| `git diff --check` | 退出码 0；无输出 |
| `git diff --cached --name-only` | 退出码 0；无输出，暂存区仍为空 |

只读复核确认：本次保存失败路径没有新增 Critical 或 Important；保存失败与 IOKit 失败可分别准确、顺序展示。未执行 GUI 写盘失败注入或真实 alert 观察，仍需人工验收。

非阻断遗留：其他非 idle 的既有 `store.update` 调用仍可选择忽略返回值，通用 `reload()` 也仍把共享 `lastError` 归为“导入失败”；这不影响本次 idle 定向闭环，但后续可把导入错误与持久化错误拆成独立通道。历史实施计划 `docs/superpowers/plans/2026-09-02-idle-display-and-manic-scale.md` 仍保留实施当时的 `.null`/通用通知示例；本次按文件所有权只更新了权威设计规格，维护时应以最新 spec 和实现为准。
