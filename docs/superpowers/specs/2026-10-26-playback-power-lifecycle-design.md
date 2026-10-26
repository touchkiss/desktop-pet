# 播放休眠恢复与长期复用

用户已确认补齐休眠/唤醒并优化播放器复用，沿用本次调查方向实施。

## 行为

- 共享监视器从 NSWorkspace.notificationCenter 接收系统与显示器的睡眠、唤醒通知。
- 两种暂停原因分别记账；重复事件幂等，所有原因解除后才恢复。
- 每个原生播放面保留片段、进度和播放意图；睡眠时取消未完成 seek，拆除快照输出，解除 layer/player/item 引用，释放媒体管线。
- 唤醒后创建新 AVPlayer/AVPlayerItem，定位原进度；原来暂停或停在终帧的播放面仍暂停，已经 stop 的播放面不创建资源。
- 主播放队列、普通预览和鼠标素材在暂停期间不推进；片段库关闭或清空详情时释放预览播放器，用户手动暂停保留画面。
- 普通播放不挂载 BGRA 快照输出；效果需要 snapshot 时才挂载，并在 seek、切片、循环、停止时移除。
- 同一 AVPlayer 最长复用 30 分钟后，在下一次切片或循环边界重建，避免中途跳帧；长片段不会在中途强制重建。该值是可测试的防护策略，不是已测得的系统故障阈值。
- 同一片段缓存 movie URL，不再每帧拼路径和执行存在性探测。片段切换仍检查文件；运行中的文件异常仍交由 AVPlayer 失败状态处理。

## 验证与边界

XCTest 使用独立 NotificationCenter 和真实 AVPlayer、透明视频 fixture，检查重叠/重复通知、待完成 seek、暂停恢复、睡眠期间换片、stop 不复活、对象销毁、输出移除和时间边界更新。纯状态在 DesktopPetCore 测试。

通知模拟不能证明真实长时间合盖后的解码状态与 CPU 已修复，也不能证明 AVFoundation 的进程级通知注册状态被完全清理。需要新版本实际合盖后继续对照；不使用强制电脑休眠来替代用户的真实使用场景。

Apple 通知文档：https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification
