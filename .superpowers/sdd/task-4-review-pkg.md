--- /Users/liushiyou/Documents/macos/desktop-pet/.superpowers/sdd/snapshots/pre-task-4/LibraryWindowController.swift	2026-08-04 20:16:04
+++ /Users/liushiyou/Documents/macos/desktop-pet/Sources/DesktopPet/LibraryWindowController.swift	2026-08-04 20:16:29
@@ -16,6 +16,10 @@
     private let launchAtLoginToggle = NSButton(checkboxWithTitle: "开机启动", target: nil, action: nil)
     private let autoLinkToggle = NSButton(checkboxWithTitle: "自动衔接", target: nil, action: nil)
     private let thresholdSlider = NSSlider()
+    private let teleportToggle = NSButton(checkboxWithTitle: "随机隐现", target: nil, action: nil)
+    private let teleportFrequencySlider = NSSlider()
+    private let cursorNudgeToggle = NSButton(checkboxWithTitle: "鼠标附近提醒", target: nil, action: nil)
+    private let editRemindersButton = NSButton(title: "编辑提醒文案…", target: nil, action: nil)
     private let progressOverlay = ProgressOverlay()
     private var isImporting = false
     private var suppressSelectionSideEffects = false
@@ -332,6 +336,30 @@
         row2.addArrangedSubview(thrLabel)
         row2.addArrangedSubview(thresholdSlider)
         row2.addArrangedSubview(NSView())
+
+        let row3 = NSStackView()
+        row3.orientation = .horizontal
+        row3.spacing = 12
+        let freqLabel = NSTextField(labelWithString: "隐现频率")
+        teleportFrequencySlider.minValue = 0
+        teleportFrequencySlider.maxValue = 1
+        teleportFrequencySlider.doubleValue = store.state.teleportFrequency
+        teleportFrequencySlider.target = self
+        teleportFrequencySlider.action = #selector(teleportSettingsChanged)
+        teleportFrequencySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
+        teleportToggle.target = self
+        teleportToggle.action = #selector(teleportSettingsChanged)
+        cursorNudgeToggle.target = self
+        cursorNudgeToggle.action = #selector(teleportSettingsChanged)
+        editRemindersButton.target = self
+        editRemindersButton.action = #selector(editReminderMessages)
+        editRemindersButton.bezelStyle = .rounded
+        row3.addArrangedSubview(teleportToggle)
+        row3.addArrangedSubview(freqLabel)
+        row3.addArrangedSubview(teleportFrequencySlider)
+        row3.addArrangedSubview(cursorNudgeToggle)
+        row3.addArrangedSubview(editRemindersButton)
+        row3.addArrangedSubview(NSView())
 
         let launchHint = NSTextField(wrappingLabelWithString: "「开机启动」会在登录时自动打开桌面宠物。若提示需要批准，请到 系统设置 → 通用 → 登录项 中允许。")
         launchHint.textColor = .secondaryLabelColor
@@ -340,6 +368,7 @@
 
         col.addArrangedSubview(row1)
         col.addArrangedSubview(row2)
+        col.addArrangedSubview(row3)
         col.addArrangedSubview(launchHint)
         wrap.addSubview(col)
 
@@ -353,7 +382,7 @@
             col.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
             col.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
 
-            wrap.heightAnchor.constraint(equalToConstant: 110)
+            wrap.heightAnchor.constraint(equalToConstant: 150)
         ])
         return wrap
     }
@@ -394,6 +423,12 @@
         scaleSlider.doubleValue = store.state.petScale
         thresholdSlider.doubleValue = store.state.autoLinkThreshold
         thresholdSlider.isEnabled = store.state.autoLinkEnabled
+        teleportToggle.state = store.state.teleportEnabled ? .on : .off
+        teleportFrequencySlider.doubleValue = store.state.teleportFrequency
+        cursorNudgeToggle.state = store.state.cursorNudgeEnabled ? .on : .off
+        teleportFrequencySlider.isEnabled = store.state.teleportEnabled
+        cursorNudgeToggle.isEnabled = store.state.teleportEnabled
+        editRemindersButton.isEnabled = store.state.teleportEnabled
 
         updateImportOverlay()
         updateCountLabel()
@@ -714,6 +749,46 @@
         showSelectedDetail()
     }
 
+    @objc private func teleportSettingsChanged() {
+        store.update {
+            $0.teleportEnabled = teleportToggle.state == .on
+            $0.teleportFrequency = teleportFrequencySlider.doubleValue
+            $0.cursorNudgeEnabled = cursorNudgeToggle.state == .on
+        }
+        teleportFrequencySlider.isEnabled = store.state.teleportEnabled
+        cursorNudgeToggle.isEnabled = store.state.teleportEnabled
+        editRemindersButton.isEnabled = store.state.teleportEnabled
+        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
+    }
+
+    @objc private func editReminderMessages() {
+        guard let parent = window else { return }
+        let alert = NSAlert()
+        alert.messageText = "提醒文案"
+        alert.informativeText = "每行一条，保存后随机抽取。"
+        alert.addButton(withTitle: "保存")
+        alert.addButton(withTitle: "取消")
+        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
+        scroll.hasVerticalScroller = true
+        scroll.borderType = .bezelBorder
+        let textView = NSTextView(frame: scroll.bounds)
+        textView.autoresizingMask = [.width, .height]
+        textView.string = store.state.reminderMessages.joined(separator: "\n")
+        textView.isRichText = false
+        textView.font = .systemFont(ofSize: 13)
+        scroll.documentView = textView
+        alert.accessoryView = scroll
+        alert.beginSheetModal(for: parent) { [weak self] response in
+            guard let self, response == .alertFirstButtonReturn else { return }
+            let lines = textView.string
+                .components(separatedBy: .newlines)
+                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
+                .filter { !$0.isEmpty }
+            self.store.update { $0.reminderMessages = lines }
+            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
+        }
+    }
+
     // MARK: Table
 
     func numberOfRows(in tableView: NSTableView) -> Int {
