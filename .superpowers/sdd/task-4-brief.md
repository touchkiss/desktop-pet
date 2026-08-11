### Task 4: Settings UI

**Files:**
- Modify: `Sources/DesktopPet/LibraryWindowController.swift`

**Interfaces:**
- Consumes: `store.state.teleport*` fields
- Produces: user can toggle/slider/edit; posts `.libraryDidChange`

- [ ] **Step 1: Add controls as properties**

Near existing toggles (`topToggle`, etc.):

```swift
private let teleportToggle = NSButton(checkboxWithTitle: "随机隐现", target: nil, action: nil)
private let teleportFrequencySlider = NSSlider()
private let cursorNudgeToggle = NSButton(checkboxWithTitle: "鼠标附近提醒", target: nil, action: nil)
private let editRemindersButton = NSButton(title: "编辑提醒文案…", target: nil, action: nil)
```

- [ ] **Step 2: Add row 3 in `makeSettings()`**

After `row2`, create horizontal `row3`:

```swift
let freqLabel = NSTextField(labelWithString: "隐现频率")
teleportFrequencySlider.minValue = 0
teleportFrequencySlider.maxValue = 1
teleportFrequencySlider.doubleValue = store.state.teleportFrequency
teleportFrequencySlider.target = self
teleportFrequencySlider.action = #selector(teleportSettingsChanged)
teleportFrequencySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
teleportToggle.target = self
teleportToggle.action = #selector(teleportSettingsChanged)
cursorNudgeToggle.target = self
cursorNudgeToggle.action = #selector(teleportSettingsChanged)
editRemindersButton.target = self
editRemindersButton.action = #selector(editReminderMessages)
editRemindersButton.bezelStyle = .rounded

row3.addArrangedSubview(teleportToggle)
row3.addArrangedSubview(freqLabel)
row3.addArrangedSubview(teleportFrequencySlider)
row3.addArrangedSubview(cursorNudgeToggle)
row3.addArrangedSubview(editRemindersButton)
row3.addArrangedSubview(NSView())
col.addArrangedSubview(row3)
```

Raise wrap height from `110` to `150`.

- [ ] **Step 3: Wire reload + actions**

In `reload`:

```swift
teleportToggle.state = store.state.teleportEnabled ? .on : .off
teleportFrequencySlider.doubleValue = store.state.teleportFrequency
cursorNudgeToggle.state = store.state.cursorNudgeEnabled ? .on : .off
teleportFrequencySlider.isEnabled = store.state.teleportEnabled
cursorNudgeToggle.isEnabled = store.state.teleportEnabled
editRemindersButton.isEnabled = store.state.teleportEnabled
```

```swift
@objc private func teleportSettingsChanged() {
    store.update {
        $0.teleportEnabled = teleportToggle.state == .on
        $0.teleportFrequency = teleportFrequencySlider.doubleValue
        $0.cursorNudgeEnabled = cursorNudgeToggle.state == .on
    }
    teleportFrequencySlider.isEnabled = store.state.teleportEnabled
    cursorNudgeToggle.isEnabled = store.state.teleportEnabled
    editRemindersButton.isEnabled = store.state.teleportEnabled
    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
}

@objc private func editReminderMessages() {
    let panel = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    panel.title = "提醒文案（每行一条）"
    let scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: 388, height: 180))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let text = NSTextView(frame: scroll.bounds)
    text.string = store.state.reminderMessages.joined(separator: "\n")
    text.isRichText = false
    text.font = .systemFont(ofSize: 13)
    scroll.documentView = text
    let save = NSButton(title: "保存", target: nil, action: nil)
    save.bezelStyle = .rounded
    save.frame = NSRect(x: 320, y: 16, width: 84, height: 28)
    let cancel = NSButton(title: "取消", target: nil, action: nil)
    cancel.bezelStyle = .rounded
    cancel.frame = NSRect(x: 230, y: 16, width: 84, height: 28)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    host.addSubview(scroll)
    host.addSubview(save)
    host.addSubview(cancel)
    panel.contentView = host

    weak var weakPanel = panel
    cancel.target = self
    // Use a small helper object or endSheet pattern:
    // Prefer: beginSheet on library window.
}
```

Implement sheet properly:

```swift
@objc private func editReminderMessages() {
    guard let parent = window else { return }
    let alert = NSAlert()
    alert.messageText = "提醒文案"
    alert.informativeText = "每行一条，保存后随机抽取。"
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let textView = NSTextView(frame: scroll.bounds)
    textView.autoresizingMask = [.width, .height]
    textView.string = store.state.reminderMessages.joined(separator: "\n")
    textView.isRichText = false
    textView.font = .systemFont(ofSize: 13)
    scroll.documentView = textView
    alert.accessoryView = scroll
    alert.beginSheetModal(for: parent) { [weak self] response in
        guard let self, response == .alertFirstButtonReturn else { return }
        let lines = textView.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.store.update { $0.reminderMessages = lines }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }
}
```

- [ ] **Step 4: Build + manual UI check**

Run: `swift build`  
Launch app, open library: see new controls; toggle enables slider; edit sheet saves lines into `library.json`.

---

