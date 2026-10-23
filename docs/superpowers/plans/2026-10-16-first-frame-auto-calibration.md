# 首帧批量标定实现计划

用户已确认使用相近首帧进行自动计算，本会话直接实现。

- [x] 在 DesktopPetCore 新增 FirstFrameSilhouette 和 FirstFrameScaleCalibration；先写测试，确认缺失实现失败，再验证最大连通主体、面积换算、相似度、绝对倍率及异常保护。
- [x] 新增 FirstFrameCalibrationAnalyzer，使用 ImageIO 缩略图读取首帧；只读分析实际素材，检查可处理和跳过结果。
- [x] 新增 ClipBatchCalibrationController，接入预览、后台分析、变化检测、一次保存、失败回滚和撤销；LibraryStore 提供批量写入口。
- [x] 在标定面板添加批量标定与撤销入口，接入详情面板及片段库刷新。
- [x] 运行 swift test、真实素材及原生控件隔离验证、git diff --check、./build_app.sh；同步 README 与验证记录。

## 验证记录

- 新增 6 项测试先因类型缺失失败，实现后通过；最终完整 swift test 为 95 项、0 失败。
- 使用本机实际素材、第一只猫作参照，152 个候选中 137 个得到建议倍率，15 个因轮廓差异跳过。此数量仅代表当前素材及当前参照下的算法判定，不是人工确认的精度。
- 使用复制到 /private/tmp 的独立 library.json，验证批量保存、过期快照拒绝、恢复原倍率、保存失败时回滚内存，全部通过。
- 原生隔离窗口验证完整分析 → 预览 sheet → 应用 → 撤销链路，全部通过；用户真实素材库倍率未改动。
- 完整 DetailPanel 初始化、倍率编辑、切换、多选、约束重接和窄窗口回归通过。界面截图保存到 docs/superpowers/screenshots/2026-10-16-first-frame-auto-calibration.png。
- 算法验证未逐一人工判断 137 个片段的视觉一致性，仍需在应用预览及最终播放中确认。预览仅列倍率变化和跳过原因。
