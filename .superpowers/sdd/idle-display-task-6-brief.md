### Task 6: Documentation and end-to-end verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: all completed runtime behavior.
- Produces: user-facing documentation and fresh verification evidence.

- [ ] **Step 1: Document controls and security boundary**

Add concise README bullets:

```markdown
- **阻止自动锁屏与关闭屏幕**：使用 macOS 显示空闲休眠断言保持屏幕常亮；不会阻止 `⌃⌘Q`、系统菜单锁屏、合盖或主动睡眠。
- **空闲魔性展示**：可在 1/3/5/10/15/30 分钟无键鼠输入后，将猫猫按 1.0×–3.0× 额外放大；恢复输入时立即回到正常大小。
```

Explain that independent screen-saver or organization/MDM policy is not bypassed.

- [ ] **Step 2: Run fresh automated verification**

Run: `swift test`

Expected: all XCTest cases pass with zero failures.

Run: `swift build`

Expected: debug build succeeds with exit code 0.

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 3: Package the app for a launch smoke test**

Run: `./build_app.sh`

Expected: release build succeeds and produces `DesktopPet.app` without tracking it.

- [ ] **Step 4: Perform the macOS-only manual checks**

Launch `DesktopPet.app`, then verify all of the following and record actual observations in the final report:

1. Toggle off/on persistence survives relaunch.
2. With a temporarily short macOS display timeout, enabled display protection prevents idle display shutoff; disabling restores system behavior.
3. `Control-Command-Q` still reaches the lock screen while protection is enabled.
4. Representative idle thresholds enter manic phase and real mouse/keyboard input immediately restores normal size.
5. A `3.0×` manic scale near each screen edge stays visible and bottom-center anchoring is stable.
6. Teleport landing, ordinary clip changes, and cursor-interaction cat clips retain the manic size; cursor-prey target point size does not change.

Do not claim any manual item passed unless it was directly observed. In particular, automated tests and a successful build do not prove macOS power-management behavior.

- [ ] **Step 5: Stage only README feature hunks and commit**

```bash
git add -p README.md
git diff --cached --check
git diff --cached
git commit -m "[文档] 说明显示保护与魔性放大设置"
```

- [ ] **Step 6: Review final scope**

Run: `git status --short` and `git log -6 --oneline`.

Expected: feature commits are visible; all pre-existing user changes remain present and uncommitted unless their exact feature hunks were deliberately staged. Compare the implementation line by line against `docs/superpowers/specs/2026-09-02-idle-display-and-manic-scale-design.md` before reporting completion.
