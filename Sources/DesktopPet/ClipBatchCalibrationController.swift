import AppKit

/// Owns the pending preview and one undo batch across detail-panel rebuilds.
@MainActor
final class ClipBatchCalibrationController {
    var onChanged: (() -> Void)?
    var onStateChanged: ((_ busy: Bool, _ canUndo: Bool) -> Void)?
    private let store: LibraryStore
    private var busy = false
    private var undoBatch: (before: [String: Double], applied: [PetClip])?

    init(store: LibraryStore) { self.store = store }

    func preview(reference: PetClip, for window: NSWindow) {
        guard !busy else { return }
        let snapshots = store.state.clips.filter { $0.libraryTab == .cats }
        guard snapshots.count > 1 else {
            showError("至少需要两个猫猫片段。", for: window)
            return
        }
        guard let liveReference = snapshots.first(where: { $0.id == reference.id }),
              liveReference.clipScale == reference.clipScale else {
            showError("参照片段已变化，请先点击“更新参照”。", for: window)
            return
        }
        setBusy(true)
        Task { [weak self, weak window] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FirstFrameCalibrationAnalyzer.analyze(reference: liveReference, clips: snapshots) }
            }.value
            guard let self else { return }
            guard let window, window.isVisible else { self.setBusy(false); return }
            switch result {
            case .failure(let error):
                self.setBusy(false)
                self.showError("参照分析失败：\(error.localizedDescription)", for: window)
            case .success(let entries):
                self.present(entries: entries, reference: liveReference, snapshots: snapshots, for: window)
            }
        }
    }

    private func present(entries: [FirstFrameCalibrationAnalyzer.Entry], reference: PetClip, snapshots: [PetClip], for window: NSWindow) {
        let changes = entries.filter { entry in
            guard let scale = entry.suggestedScale else { return false }
            return abs(scale - entry.originalScale) > 0.000001
        }
        let alert = NSAlert()
        alert.messageText = "首帧批量标定预览"
        let skipped = entries.filter { $0.suggestedScale == nil }.count
        alert.informativeText = "参照：\(reference.name)（\(String(format: "%.3f", reference.clipScale))×）\n将调整 \(changes.count) 个，跳过 \(skipped) 个；参照自身保持不变。只使用首帧，不改变图像文件或桌面位置。"
        if !changes.isEmpty { alert.addButton(withTitle: "应用 \(changes.count) 个") }
        alert.addButton(withTitle: changes.isEmpty ? "关闭" : "取消")

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 470, height: 280))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = entries.map { entry in
            if let scale = entry.suggestedScale {
                let unchanged = abs(scale - entry.originalScale) <= 0.000001
                return "\(entry.name)\n  \(String(format: "%.3f", entry.originalScale))× → \(String(format: "%.3f", scale))×\(unchanged ? "（无需修改）" : "")"
            }
            return "\(entry.name)\n  跳过：\(entry.note)"
        }.joined(separator: "\n\n")
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: 280))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self else { return }
            self.setBusy(false)
            guard response == .alertFirstButtonReturn, !changes.isEmpty, let window else { return }
            let scales = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0.suggestedScale!) })
            let checkedSnapshots = snapshots.filter { scales[$0.id] != nil || $0.id == reference.id }
            if let error = self.store.applyClipScales(scales, expected: checkedSnapshots) {
                self.store.consumeLastError(ifMatching: error)
                self.showError(error, for: window)
                return
            }
            let before = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0.originalScale) })
            self.undoBatch = (before, self.store.state.clips.filter { scales[$0.id] != nil })
            self.onStateChanged?(false, true)
            self.onChanged?()
        }
    }

    func undo(for window: NSWindow) {
        guard !busy, let batch = undoBatch else { return }
        if let error = store.applyClipScales(batch.before, expected: batch.applied) {
            store.consumeLastError(ifMatching: error)
            showError(error, for: window)
            return
        }
        undoBatch = nil
        onStateChanged?(false, false)
        onChanged?()
    }

    private func setBusy(_ value: Bool) {
        busy = value
        onStateChanged?(value, undoBatch != nil)
    }

    private func showError(_ message: String, for window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "首帧批量标定"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}
