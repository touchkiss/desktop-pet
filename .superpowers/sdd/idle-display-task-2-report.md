# Task 2：可测试的 display-sleep lease

## 实现

新增 `IdleDisplaySleepLease` 通用生命周期状态机，注入 `acquire: () throws -> UInt32` 与 `release: (UInt32) throws -> Void`。`isEnabled` 由本地 assertion ID 派生；启用/禁用均幂等。获取失败不写入状态；释放前先清除状态，即使释放抛错也不会残留本地 lease；析构时尽力释放仍持有的 assertion。未引入真实 IOKit 适配。

## 测试与 RED/GREEN

- RED：先新增三条生命周期测试，运行 `swift test --filter IdleDisplaySleepLeaseTests`，编译器报告 `cannot find 'IdleDisplaySleepLease' in scope`。
- GREEN：实现最小状态机后，同一聚焦命令通过 3/3。
- 全量：`swift test` 通过 72/72，0 failures。

## 文件与提交

- `Sources/DesktopPetCore/IdleDisplaySleepLease.swift`
- `Tests/DesktopPetTests/IdleDisplaySleepLeaseTests.swift`
- 提交：`d12dfa8 [电源] 新增显示休眠断言租约状态机`

## Self-review

- API 与 brief 一致，类型与成员均为 `public`，闭包生命周期与抛错语义清晰。
- 状态转换覆盖 enable/disable 幂等、acquire 失败、release 失败和析构兜底；staged diff 仅含上述两个文件，`git diff --cached --check` 无输出。
- 后续 IOKit 适配可直接注入 acquire/release；当前类未做并发同步，符合本任务“通用可测试状态机”范围。

## Concerns

真实 IOKit assertion 创建/释放、权限和线程归属尚未实现，留给后续任务；析构释放采用 `try?`，因此底层释放失败只能静默丢弃，这是 brief 指定的最佳努力清理策略。
