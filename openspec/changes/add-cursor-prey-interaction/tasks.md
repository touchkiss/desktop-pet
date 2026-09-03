## 1. 互动规则与数据模型

- [x] 1.1 在 `Tests/DesktopPetTests/CursorInteractionPolicyTests.swift` 先添加失败测试，覆盖 16/128 pt 边界、越界限制、默认 48 pt，以及仅自主 `.cursorNudge` 且两类素材齐全时可互动。
- [x] 1.2 在 `Sources/DesktopPetCore/CursorInteractionPolicy.swift` 实现可测试的尺寸常量、限制函数和触发资格判断，运行 `swift test --filter CursorInteractionPolicyTests` 确认通过。
- [x] 1.3 在 `Sources/DesktopPet/Models.swift` 增加 `ClipTag.cursorPrey`、`ClipTag.cursorInteraction`、可选 `CursorPreySettings` 与向后兼容 Codable 解码；旧 JSON 缺字段时保持普通素材和 `nil` 配置。
- [x] 1.4 在 `Sources/DesktopPet/LibraryStore.swift` 增加逐片段标签互斥处理及目标尺寸更新 API；取消目标标签时保留最后尺寸，首次启用时写入 48 pt 默认值。
- [x] 1.5 修改 `LibraryState.playableClips` 与 `TransitionMatcher.rebuildAutoLinks`，排除两类专用素材并忽略旧队列中的专用 ID；验证普通片段顺序和现有行为标签不受影响。

## 2. 素材库配置界面

- [x] 2.1 在 `Sources/DesktopPet/LibraryWindowController.swift` 的片段详情加入“鼠标互动目标素材”和“鼠标互动猫片段”复选框，并连接 `LibraryStore` 的互斥标签更新 API。
- [x] 2.2 仅在当前片段为 `cursorPrey` 时显示 16–128 pt 滑块、当前 pt 数值和“恢复默认”按钮，所有操作只更新当前片段的 `CursorPreySettings`。
- [x] 2.3 扩展 `ClipPreviewPlayer` 或增加聚焦的小型预览视图，使目标素材按当前 pt 值等比循环预览，滑块和恢复默认操作即时刷新且不重新导出 PNG。
- [x] 2.4 调整素材行和详情提示，明确专用素材不参与普通播放；标记变更后刷新队列、自动衔接展示和播放起点，避免播放器停留在刚变成专用素材的片段。

## 3. 一次性互动播放

- [x] 3.1 为 `PlaylistEngine` 添加一次性播放状态和 API，使传送末帧 hold 中待播放的普通片段成为恢复目标，并从第一帧播放指定 `cursorInteraction` 片段。
- [x] 3.2 修改 `PlaylistEngine.tick()`：一次性片段结束时不调用常规 next-clip 选择和随机传送回调，而是调用一次完成回调并恢复有效普通片段；恢复目标失效时回退到首个 `playableClips`。
- [x] 3.3 确保 `stop()`、普通 `playClip(id:)` 和素材删除会取消一次性上下文，且空普通播放集合安全停止，不把任何专用素材当作回退片段。
- [x] 3.4 添加针对一次性播放状态转换的可重复测试或抽取纯状态机到 `DesktopPetCore` 测试，覆盖正常结束、取消、恢复目标失效及重复结束。

## 4. 动态鼠标目标覆盖层

- [x] 4.1 新建 `Sources/DesktopPet/CursorPreyOverlayController.swift`，创建透明无边框、置顶、跨 Space、`ignoresMouseEvents = true` 的窗口，并定义 `start(clip:settings:) -> Bool` 与幂等 `stop()` 接口。
- [x] 4.2 按目标片段 fps 循环加载透明 PNG 帧，按独立 `displaySize` 等比调整窗口，并用主线程计时器持续把窗口中心对齐 `NSEvent.mouseLocation`。
- [x] 4.3 只在窗口与首帧成功显示后保存原前台应用、短暂激活 DesktopPet 并全局隐藏系统指针，再立即恢复原应用；由控制器保证激活超时、`stop()`、初始化失败和释放路径幂等恢复指针与焦点。
- [x] 4.4 在帧缺失、后续加载失败和显示器切换时安全停止并通知上层取消互动；释放帧缓存、窗口和全部计时器。

## 5. 传送互动编排与清理

- [x] 5.1 在 `TeleportController` 区分片尾随机、显式召唤和预览来源；只为自主随机 `.cursorNudge` 且无显式到达消息的旅程调用互动资格判断。
- [x] 5.2 从 `LibraryStore` 的有效 `cursorPrey` 与 `cursorInteraction` 候选中分别随机选择一份并保存本轮上下文；任一候选缺失或首帧不可用时保持现有提醒流程。
- [x] 5.3 在普通出现路径和像素洪流到达路径共用一个着陆准备方法：先启动目标覆盖层，再从第一帧启动一次性互动猫片段，最后让出现画面使用该片段。
- [x] 5.4 互动猫片段正常结束时停止覆盖层、恢复系统指针、清除上下文并继续普通播放；互动期间禁止片尾随机触发另一轮传送。
- [x] 5.5 把拖拽/甩动、隐藏宠物、新传送、素材库变更、帧加载失败、控制器 `stop()` 和应用退出统一接入幂等清理方法，重复调用不得重复恢复指针或错误推进播放。
- [x] 5.6 确认 `summonToCursor`、番茄钟、下载提醒和特效预览均不创建互动上下文，并继续显示原有到达气泡。

## 6. 验证与文档

- [x] 6.1 运行 `swift test`，确认全部新旧 XCTest 通过且没有编译警告。
- [x] 6.2 运行 `./build_app.sh`，确认 release 构建和 `DesktopPet.app` 打包成功。
- [ ] 6.3 手工验证不同尺寸的苍蝇、小虫、逗猫棒和猫玩具可分别保存、实时预览并随机配对，专用素材不会进入普通播放或衔接。
- [ ] 6.4 手工验证目标跨应用和多显示器跟随时不拦截点击、拖动或滚动，并在正常结束、拖猫、隐藏、新传送、删除素材及退出时立即恢复系统指针。
- [x] 6.5 更新 `README.md` 的互动、片段标签、鼠标附近提醒和数据说明，记录专用素材导入方式、逐素材尺寸范围及触发限制。
