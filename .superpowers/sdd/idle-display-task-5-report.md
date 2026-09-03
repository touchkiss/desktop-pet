# Task 5 报告：真实 IOKit 显示保护与 HID 空闲运行时接线

## 结论

Task 5 已完成系统接线。项目在 macOS 27 SDK / Swift 6.4 工具链下成功编译，完整 XCTest 套件 77/77 通过。未执行实际锁屏，也未启动应用触发现实系统电源状态变化。

## 实现

### IOKit 显示保护适配器

- 新增 `IOKitIdleDisplaySleepController`，以现有 `IdleDisplaySleepLease` 管理断言生命周期。
- 获取断言只调用 `IOPMAssertionCreateWithName`，类型严格为 `kIOPMAssertionTypePreventUserIdleDisplaySleep`。
- 释放只调用 `IOPMAssertionRelease`。
- IOKit 非成功返回码封装为 `IOKitPowerAssertionError`，提供中文本地化错误信息。
- 重复启用、重复停用和失败后的本地状态均沿用已测试 lease 的幂等语义。
- macOS 27 SDK 的实际类型签名可直接接受 brief 中的 `IOPMAssertionID` / `IOPMAssertionLevel` 写法，无需额外适配。

### 链接配置

- 在 `DesktopPet` executable target 中新增 `.linkedFramework("IOKit")`，保留原有 `ServiceManagement` 与 `Carbon` 配置。

### AppDelegate 运行时接线

- 启动并打开片段库窗口后，立即从持久化 `preventIdleDisplaySleep` 状态同步系统断言。
- 启动时立即采样一次 HID 空闲时长，随后用 1 秒 repeating timer 在主 run loop `.common` mode 持续采样。
- 空闲值来自 `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)`。
- 使用 `IdlePresentationPolicy.phase` 计算阶段，只有阶段发生变化时才调用 `PetWindowController.setIdlePresentationPhase`。
- `handleLibraryChange` 在现有帧刷新分支前同步显示保护设置并更新空闲展示阶段。
- 创建或释放断言失败时，将持久化 checkbox 状态恢复为 `false`，调用现有 library error hook，并发送一次 library change 使 UI 恢复；恢复 guard 防止在回退写入过程中重入同步逻辑。
- 菜单退出路径立即 best-effort 释放断言；`applicationWillTerminate` 还会失效空闲 timer 并再次幂等释放。

## 验证

### 构建

命令（使用 `/tmp` 模块缓存规避宿主用户缓存不可写）：

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/desktop-pet-task5-module-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/desktop-pet-task5-swiftpm-cache \
  swift build
```

结果：`Build complete!`，退出码 0；IOKit 符号成功编译链接，无 unresolved-symbol 错误。

### 测试

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/desktop-pet-task5-module-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/desktop-pet-task5-swiftpm-cache \
  swift test
```

结果：执行 77 个 XCTest，0 failures / 0 unexpected；Swift Testing 的空测试运行也为 0 failures。

### 静态边界检查

- `git diff --check` 通过。
- 以 `.superpowers/sdd/idle-display-task-5-before/AppDelegate.swift` 为基线审查，当前 AppDelegate 增量只包含 Task 5 的属性、启动同步/timer、library change 同步、HID 采样和退出清理。
- 扫描 Task 5 相关文件，只发现 `kIOPMAssertionTypePreventUserIdleDisplaySleep`；未引入 `DeclareUserActivity`、`caffeinate`、合成 `CGEvent`、锁屏 API 或锁屏路径接管。
- 未实际锁屏，符合任务安全限制。

## Self-review

- 阶段通知：`guard phase != currentIdlePresentationPhase` 确保不按秒重复通知 PetWindow。
- 设置恢复：获取失败时 lease 不会宣称 enabled；回退保存为 false 后的通知再次同步到 disabled，不会重复创建断言或形成错误通知循环。
- 释放失败：lease 先清除本地 assertion ID，因此退出回调中的重复停用安全；失败仅记录日志或走设置回退 UI。
- 生命周期：启动恢复保存状态，菜单退出立即释放，终止回调失效 timer 并 best-effort 再释放。
- 手动锁屏：未修改或增加任何手动锁屏逻辑；显示保护断言不会伪造用户活动。
- 并发修改保护：AppDelegate 按任务前快照做最小增量，没有撤销、重排或暂存已有鼠标互动改动。

## 文件与提交边界

已提交：

- `Package.swift`
- `Sources/DesktopPet/IOKitIdleDisplaySleepController.swift`

提交：`aa63242`（`[电源] 接入空闲显示保护与魔性阶段计时`）

按安全规则保留为未暂存：

- `Sources/DesktopPet/AppDelegate.swift`（包含 Task 5 接线，也包含其他工作者/用户现有修改；从未 stage 或 commit）

本报告也不在上述代码提交中。

## 已知限制 / concerns

- 自动化验证覆盖 lease 和策略核心逻辑、应用编译链接与现有回归套件；没有启动 GUI 应用实际创建 IOKit assertion，因此真实系统电源断言的 acquire/release 行为仍需后续在人工验收环境中验证。
- 首次沙箱内构建在 SwiftPM 嵌套 `sandbox-exec` 阶段被系统拒绝；在获准的沙箱外、使用任务专用 `/tmp` 模块缓存后，构建和测试均通过。这是验证环境限制，不是编译错误。
