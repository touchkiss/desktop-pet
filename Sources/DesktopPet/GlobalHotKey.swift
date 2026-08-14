import Carbon.HIToolbox
import Foundation

/// Minimal Carbon hot-key wrapper — system-wide, and unlike NSEvent global
/// monitors it needs no accessibility grant.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init?(keyCode: UInt32, carbonModifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var installedHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    hotKey.callback()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &installedHandler
        )
        guard installStatus == noErr else { return nil }
        handlerRef = installedHandler

        var registeredHotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4450_4554), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registerStatus == noErr else {
            if let installedHandler {
                RemoveEventHandler(installedHandler)
            }
            return nil
        }
        hotKeyRef = registeredHotKey
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
