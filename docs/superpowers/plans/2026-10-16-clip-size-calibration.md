# 猫猫尺寸标定实现计划

**Goal:** 在片段详情用固定首帧参照精调猫猫尺寸。

**Architecture:** Core 保存可测试几何与输入规则；独立 AppKit 标定视图读取已有 PNG；DetailPanel 复用尺寸保存回调。参照 ID 保存到 UserDefaults。

**Tech Stack:** Swift 5.9、AppKit、XCTest，macOS 13+，无新增依赖。

## Task 1：标定计算

- [x] 新建 Tests/DesktopPetTests/ClipCalibrationGeometryTests.swift，测试共同比例、底部居中、偏移、无效值、参照回退和输入。
- [x] 执行 swift test --filter ClipCalibrationGeometryTests，确认缺失实现导致失败。
- [x] 新建 Sources/DesktopPetCore/ClipCalibrationGeometry.swift；提供 fitScale(current:reference:canvas:)、imageRect(size:canvas:scale:offset:)、referenceID(preferred:available:)、parsedClipScale(_:)，非法输入返回 nil，合法输入沿用范围钳制。
- [x] 重新执行定向测试，确认通过。

## Task 2：标定界面与联动

- [x] 新建 Sources/DesktopPet/ClipCalibrationView.swift：持有参照快照、当前图片和帧滑块，绘制统一比例画布，实现参照下拉、更新参照、显示开关、透明度、辅助线、拖动、复位和画布缩放。
- [x] 修改 Sources/DesktopPet/LibraryWindowController.swift：在现有倍率下加入标定画布；增加倍率输入并联动滑块，保留原动态预览。
- [x] 切换目标素材或多选时释放图片；同一片段刷新保留标定姿势和拖动位置；参照缺失回退且给出提示。
- [x] swift test 与 swift build；检查 git diff --check。

## Task 3：验证与交付

- [x] 用隔离 AppKit 窗口和真实猫猫素材检查画布及完整 DetailPanel，保存截图。
- [x] 执行 ./build_app.sh，记录全部验证结果与未验证边界。
- [x] 更新 README 中的尺寸标定使用说明，将本计划复选框同步到实际完成情况。

## 验证记录

- 6 项新测试先因缺失 ClipCalibrationGeometry 失败，实现后通过。最终 swift test：89 项，0 失败。
- 原生隔离验证使用真实猫猫素材，覆盖参照快照固定、更新参照、ID 保存、透明度和选帧，结果通过。
- 完整 DetailPanel 验证覆盖输入保存回调、非法输入恢复、范围钳制、未编辑倍率不被显示舍入改写、同片段刷新、多选和切换后的约束重接、367 pt 窄详情布局，结果通过。未写入素材库倍率。
- 原生验证发现宽度约束在加入父容器之前激活会抛异常；改为先添加子视图，再启用跨视图约束，回归通过。
- 倍率滑块和输入框移到标定画布正下方，便于同时观察和调整。
- 最终 ./build_app.sh 成功，生成 DesktopPet.app；git diff --check 通过。
- 截图：docs/superpowers/screenshots/2026-10-16-clip-size-calibration.png。
- 未进行真实鼠标拖动的端到端操作；拖动几何有单元测试，原生绘制和控件有隔离验证。未验证其他 macOS 版本。不同姿态的视觉体型仍需人工判断。
