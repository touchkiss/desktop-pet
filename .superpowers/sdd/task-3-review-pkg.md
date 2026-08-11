# Task 3 review package
--- /Users/liushiyou/Documents/macos/desktop-pet/.superpowers/sdd/snapshots/pre-task-3/Models.swift	2026-08-04 20:11:14
+++ /Users/liushiyou/Documents/macos/desktop-pet/Sources/DesktopPet/Models.swift	2026-08-04 20:12:06
@@ -1,4 +1,5 @@
 import Foundation
+import DesktopPetCore
 
 enum PlaybackMode: String, Codable, CaseIterable, Identifiable {
     case sequential
@@ -76,6 +77,10 @@
     var autoLinkEnabled: Bool
     /// If non-empty, playback only cycles through these clip IDs (in order for sequential).
     var activeQueue: [String]
+    var teleportEnabled: Bool
+    var teleportFrequency: Double
+    var cursorNudgeEnabled: Bool
+    var reminderMessages: [String]
 
     static let empty = LibraryState(
         clips: [],
@@ -85,7 +90,11 @@
         clickThrough: false,
         autoLinkThreshold: 0.82,
         autoLinkEnabled: true,
-        activeQueue: []
+        activeQueue: [],
+        teleportEnabled: false,
+        teleportFrequency: 0.5,
+        cursorNudgeEnabled: false,
+        reminderMessages: TeleportMath.defaultReminderMessages
     )
 
     /// Clips participating in the current play cycle.
@@ -97,6 +106,7 @@
     enum CodingKeys: String, CodingKey {
         case clips, playbackMode, petScale, alwaysOnTop, clickThrough
         case autoLinkThreshold, autoLinkEnabled, activeQueue
+        case teleportEnabled, teleportFrequency, cursorNudgeEnabled, reminderMessages
     }
 
     init(
@@ -107,7 +117,11 @@
         clickThrough: Bool,
         autoLinkThreshold: Double,
         autoLinkEnabled: Bool,
-        activeQueue: [String]
+        activeQueue: [String],
+        teleportEnabled: Bool,
+        teleportFrequency: Double,
+        cursorNudgeEnabled: Bool,
+        reminderMessages: [String]
     ) {
         self.clips = clips
         self.playbackMode = playbackMode
@@ -117,6 +131,10 @@
         self.autoLinkThreshold = autoLinkThreshold
         self.autoLinkEnabled = autoLinkEnabled
         self.activeQueue = activeQueue
+        self.teleportEnabled = teleportEnabled
+        self.teleportFrequency = teleportFrequency
+        self.cursorNudgeEnabled = cursorNudgeEnabled
+        self.reminderMessages = reminderMessages
     }
 
     init(from decoder: Decoder) throws {
@@ -129,6 +147,11 @@
         autoLinkThreshold = try c.decode(Double.self, forKey: .autoLinkThreshold)
         autoLinkEnabled = try c.decode(Bool.self, forKey: .autoLinkEnabled)
         activeQueue = try c.decodeIfPresent([String].self, forKey: .activeQueue) ?? []
+        teleportEnabled = try c.decodeIfPresent(Bool.self, forKey: .teleportEnabled) ?? false
+        teleportFrequency = try c.decodeIfPresent(Double.self, forKey: .teleportFrequency) ?? 0.5
+        cursorNudgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorNudgeEnabled) ?? false
+        reminderMessages = try c.decodeIfPresent([String].self, forKey: .reminderMessages)
+            ?? TeleportMath.defaultReminderMessages
     }
 }
 

## TeleportMath defaultReminderMessages hunk
--- /Users/liushiyou/Documents/macos/desktop-pet/.superpowers/sdd/snapshots/pre-task-3/TeleportMath.swift	2026-08-04 20:11:14
+++ /Users/liushiyou/Documents/macos/desktop-pet/Sources/DesktopPetCore/TeleportMath.swift	2026-08-04 20:11:43
@@ -2,6 +2,12 @@
 import CoreGraphics
 
 public enum TeleportMath {
+    public static let defaultReminderMessages = [
+        "喝点水吧",
+        "站起来走走",
+        "看看远处放松一下"
+    ]
+
     public static func clamp01(_ value: Double) -> Double {
         min(1, max(0, value))
     }
