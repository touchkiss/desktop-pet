# Playback power lifecycle implementation plan

**Goal:** 按用户确认的方向补齐休眠恢复，限制原生播放器长期复用。

**Architecture:** 纯状态管理系统/显示器两个暂停原因；共享 NSWorkspace 通知监视器广播状态。所有 AlphaVideoPlayback 使用该状态，在睡眠时保留进度与播放意图并释放 player/item/output，完全唤醒后重建。暂停预览保持暂停，停止的播放器不恢复。片段边界按运行时间（默认 30 分钟）更新播放器，减少同一 AVPlayer 无期限复用；这只是防护策略，不代表已证明系统内部泄漏。快照输出按需挂载，在切片/循环/停止时移除。

**Tech Stack:** Swift、AppKit、AVFoundation、XCTest，macOS 13+。

## Constraints
- 不强制电脑睡眠；真实长时间合盖性能另行验证。
- 保留 seek generation 防过期回调、帧时钟、暂停/终帧语义。
- 不改变媒体库和用户设置；不提交已有 .DS_Store 修改。

## Tasks
- [x] 增加纯暂停状态与媒体集成回归测试，先运行观察失败。
- [x] 实现共享电源监视、视频释放与恢复、播放器边界更新、按需输出。
- [x] 阻止预览与鼠标素材的休眠期间帧推进，覆盖停止/切片/未完成 seek/重叠通知。
- [x] 运行 swift test、release 打包及 diff 检查，自审变更并记录验证边界。

## 执行结果

- 已观察新增媒体测试因缺失生命周期接口而失败，再实现并通过。
- `swift test`：96 个核心测试、15 个媒体测试全部通过，0 失败，编译无警告。
- `./build_app.sh`：release 构建、DesktopPet.app 打包成功，无编译警告。
- `git diff --check` 通过；独立只读代码审查未发现重要问题。
- 已重启运行新包，PID 36262。实际长时间合盖后 CPU 仍待验证。
- 额外收尾：关闭片段库或清空详情时真正释放预览资源；手动暂停仍保留画面。
- 新包短时 `top` 六个有效区间为 2.5%、3.1%、5.5%、2.9%、3.1%、3.1%，均值约 3.37%；随机素材场景，不能作为严格同素材基准。原始数据：`/tmp/desktop-pet-lifecycle-runtime.top.txt`。
