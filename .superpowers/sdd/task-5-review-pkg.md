--- /Users/liushiyou/Documents/macos/desktop-pet/.superpowers/sdd/snapshots/pre-task-5/PetWindowController.swift	2026-08-04 20:18:00
+++ /Users/liushiyou/Documents/macos/desktop-pet/Sources/DesktopPet/PetWindowController.swift	2026-08-04 20:18:18
@@ -6,6 +6,8 @@
         didSet { needsDisplay = true }
     }
 
+    var onDragBegan: (() -> Void)?
+
     private var dragOffset: NSPoint?
 
     override var isOpaque: Bool { false }
@@ -31,6 +33,7 @@
     }
 
     override func mouseDown(with event: NSEvent) {
+        onDragBegan?()
         guard let window else { return }
         let loc = event.locationInWindow
         dragOffset = NSPoint(x: loc.x, y: loc.y)
@@ -59,6 +62,10 @@
     private let engine: PlaylistEngine
     private var frameCache: (clipID: String, index: Int, image: NSImage)?
 
+    var onTeleportDragCancel: (() -> Void)?
+
+    var effectHost: PetContentView { contentView }
+
     init(store: LibraryStore, engine: PlaylistEngine) {
         self.store = store
         self.engine = engine
@@ -85,6 +92,10 @@
         contentView.layer?.backgroundColor = NSColor.clear.cgColor
         window.contentView = contentView
 
+        contentView.onDragBegan = { [weak self] in
+            self?.onTeleportDragCancel?()
+        }
+
         restoreOrPositionDefault()
         applyWindowFlags()
         refreshFrame()
@@ -108,6 +119,28 @@
         fatalError("init(coder:) has not been implemented")
     }
 
+    func currentPetFrame() -> CGRect {
+        window?.frame ?? .zero
+    }
+
+    func setPetHiddenForTeleport(_ hidden: Bool) {
+        contentView.isHidden = hidden
+    }
+
+    func movePetForTeleport(to origin: CGPoint) {
+        guard let window else { return }
+        window.setFrameOrigin(origin)
+        UserDefaults.standard.set(origin.x, forKey: "petOriginX")
+        UserDefaults.standard.set(origin.y, forKey: "petOriginY")
+    }
+
+    func restorePetPresentation() {
+        contentView.isHidden = false
+        contentView.alphaValue = 1
+        contentView.layer?.opacity = 1
+        contentView.layer?.transform = CATransform3DIdentity
+    }
+
     func applyWindowFlags() {
         guard let window else { return }
         window.level = store.state.alwaysOnTop ? .floating : .normal
