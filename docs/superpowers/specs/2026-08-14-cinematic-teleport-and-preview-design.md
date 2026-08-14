# 电影级隐现升级 + 素材库整段预览 — 设计规格

日期：2026-08-14
状态：已确认（Necksas 批准）

## 背景

随机隐现的消失/出现特效已修复三个基础 bug（出现特效不可见、快照含 padding 尺寸跳变、粒子硬切）。本次在此基础上实现三项电影级升级与一项素材库改进：

1. 穿越光痕：消失点与出现点之间的可见能量轨迹
2. 残影拖尾：CAReplicatorLayer 动作拖影
3. 噪声溶解：逐像素碎块状溶解，替换 ash 的平滑渐变擦除
4. 素材库详情区整段视频预览（此前只显示首/尾帧）

## 已确认的决策

- 光痕**每次隐现都出现**，配色随特效风格匹配（暖金 / beam、blink 用冷蓝）
- 预览播放器：**自动循环 + 播放/暂停按钮 + 可拖动进度条 + 帧数显示**
- **全链路方向连贯**：落点提前到 beginTrip 解析；消失特效收到"去向"、光痕沿弧线飞行、出现特效从"来向"滑入。代价（接受）：鼠标附近提醒的落点按"消失时刻"的鼠标位置计算

## 组件设计

### 1. TravelStreakRenderer（新文件，Sources/DesktopPet/）

- 独立透明 NSWindow：borderless、clear、无阴影、`ignoresMouseEvents=true`、`.floating` 层级、`canJoinAllSpaces + fullScreenAuxiliary`；frame 为起点/落点/控制点的包围盒外扩 140px（NSWindow 可跨显示器）。飞行结束后 `orderOut` 并释放引用
- 轨迹为二次贝塞尔弧线：控制点在弦的垂直方向偏移 12%–20% 弦长（随机取边）
- 彗星头：调色板着色的径向光晕 + 高亮核心，`CAKeyframeAnimation(path:, calculationMode: .paced)` 沿弧线飞行；包在 CAReplicatorLayer（instanceCount 6、instanceDelay 0.022、alphaOffset −0.16）中形成残影
- 尾迹：CAShapeLayer 描边 strokeEnd 先行、strokeStart 追赶（彗尾收束）；CAEmitterLayer 的 emitterPosition 沿同一路径撒微粒
- 抵达闪光：落点处光晕在到达瞬间弹一下
- 时序：`completion` 在头部抵达时触发（接出现特效）；窗口再保留 0.5s 让尾迹淡出后关闭
- `cancel()` 撤销两个延迟任务并立即关窗

### 2. TeleportMath 纯函数扩展（DesktopPetCore）

- `travelDuration(distance:)` = clamp(0.3, distance/2400, 0.65) 秒
- `travelControlPoint(from:to:bulgeUnit:sideUnit:)` — 弧线控制点（垂直偏移 lerp(0.12, 0.20, bulgeUnit) × 弦长，sideUnit 决定偏向哪一侧）
- 两者补 XCTest 单元测试

### 3. TeleportController 时序改造

- `beginTrip` 内解析落点（原在 enterHidden），记录起终点中心与单位方向向量
- `playVanish(style:onPet:towards:)` 传入去向
- `enterHidden`：移动窗口 → 静默等待 `max(0.05, hiddenPause − travelDuration)` → 光痕起飞 → 抵达回调进入 `beginAppear`（传入来向）
- `cancelInFlight` 同步 `streak.cancel()`

### 4. TeleportEffectRenderer 升级

- `playVanish/playAppear` 增加 `towards direction: CGVector?` 可选参数
- **blink** 改"瞬移步"：消失时先向反方向微退再朝去向冲出约 60px；出现时从来向滑入并回弹沉降。猫的快照层包进 CAReplicatorLayer（5 实例、0.03s 递延、透明度递减）产生冲刺拖影；tail 提升到 0.2s 覆盖残影收尾
- **ash（噪声溶解）**：预生成噪声带遮罩位图（低分辨率值噪声双线性放大 + 横向 ramp 阈值化，边界呈碎块状），作为 mask layer 以 position 动画滑过快照层，实现逐像素蚕食式溶解；溶解前沿方向与去向/来向的水平分量一致，尘埃发射器前沿与粒子飘散方向同步镜像。不做逐帧 Core Image 渲染（首帧延迟与 GPU 预热风险）
- 其余四种特效不做位移改动

### 5. 素材库整段预览（LibraryWindowController / DetailPanel）

- 新增 `ClipPreviewPlayer`（NSView）：240×240 预览区、棋盘格底纹衬托透明通道；Timer 按 `clip.fps` 循环播放 `frames/%05d.png` 序列
- 控件行：播放/暂停按钮（SF Symbol）+ 可拖动进度条（1…frameCount）+ "N / M 帧"标签
- 帧图按需加载 + FIFO 缓存（上限 40 帧）；切换选择 / 多选 / 视图离开窗口时停止 Timer
- 首帧/尾帧缩略图保留（衔接编辑参考），移至播放器下方

## 错误处理与边界

- 光痕窗口在拖拽取消、隐现关闭、宠物隐藏时立即撤销；completion 不触发（控制器 phase 守卫兜底）
- 距离趋近 0 时 travelDuration 取下限 0.3s，弧线退化为微小弧，不影响时序
- 已知边界：显示器"单独 Space"设置差异下，光痕窗口可能被全屏窗口遮挡；如出现再调层级
- 本容器无法编译 AppKit：交付后需本地 `./build_app.sh` 验证 + `swift test` 跑单元测试

## 测试

- TeleportMathTests：travelDuration 端点与钳制；travelControlPoint 中点偏移量与垂直性
- 手动验证清单：六种特效 × 消失/出现、光痕跨屏、拖拽取消、blink 拖影方向、ash 溶解方向、预览播放器（播放/暂停/拖动进度/切换片段/关窗）
