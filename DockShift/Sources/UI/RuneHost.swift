import AppKit
import QuartzCore

@_silgen_name("ds_create") private func runeCreate(_ layer: UnsafeMutableRawPointer, _ width: Float, _ height: Float, _ scale: Float, _ dark: Bool, _ json: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("ds_destroy") private func runeDestroy(_ host: UnsafeMutableRawPointer)
@_silgen_name("ds_update") private func runeUpdate(_ host: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>)
@_silgen_name("ds_resize") private func runeResize(_ host: UnsafeMutableRawPointer, _ width: Float, _ height: Float, _ scale: Float)
@_silgen_name("ds_frame") private func runeFrame(_ host: UnsafeMutableRawPointer) -> Bool
@_silgen_name("ds_pointer") private func runePointer(_ host: UnsafeMutableRawPointer, _ kind: Int32, _ x: Float, _ y: Float, _ dy: Float)
@_silgen_name("ds_wheel") private func runeWheel(_ host: UnsafeMutableRawPointer, _ x: Float, _ y: Float, _ dx: Float, _ dy: Float)
@_silgen_name("ds_key") private func runeKey(_ host: UnsafeMutableRawPointer, _ key: UnsafePointer<CChar>, _ mods: UInt32)
@_silgen_name("ds_text") private func runeText(_ host: UnsafeMutableRawPointer, _ text: UnsafePointer<CChar>)
@_silgen_name("ds_ime") private func runeIME(_ host: UnsafeMutableRawPointer, _ text: UnsafePointer<CChar>, _ start: UInt, _ end: UInt, _ commit: Bool)
@_silgen_name("ds_select") private func runeSelect(_ host: UnsafeMutableRawPointer, _ id: UnsafePointer<CChar>)
@_silgen_name("ds_actions") private func runeActions(_ host: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?
@_silgen_name("ds_copy") private func runeCopy(_ host: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?
@_silgen_name("ds_elements") private func runeElements(_ host: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?
@_silgen_name("ds_free") private func runeFree(_ string: UnsafeMutablePointer<CChar>)

/// A native input/accessibility host only. All custom pixels, layouts, focus, fields, menus,
/// dialogs and animation are Rune. Idle windows skip rendering; hidden windows stop ticking.
@MainActor
final class RuneHost: NSView, @MainActor NSTextInputClient {
    let bridge: RuneBridge
    nonisolated(unsafe) private var handle: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var timer: Timer?
    private var metal: CAMetalLayer { layer as! CAMetalLayer }
    private var needsFrames = true
    private var lastModel = Date.distantPast
    private var lastJSON = ""
    private var tracking: NSTrackingArea?
    private var marked = ""
    private var accessibilityItems: [String: RuneAccessible] = [:]
    private var lastAccessibility = ""
    private var failed = false
    private var windowDark: Bool?

    private func updateWindowAppearance() {
        let dark = UserDefaults.standard.object(forKey: "rune.dark") as? Bool
            ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if windowDark != dark {
            windowDark = dark
            window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }

    init(bridge: RuneBridge) {
        self.bridge = bridge
        super.init(frame: .zero)
        wantsLayer = true
        layer = CAMetalLayer()
        metal.isOpaque = true
        metal.presentsWithTransaction = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { timer?.invalidate(); if let handle { runeDestroy(handle) } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { timer?.invalidate(); timer = nil; return }
        updateWindowAppearance()
        if handle == nil && !failed {
            let snapshot = bridge.snapshot()
            let dark = UserDefaults.standard.object(forKey: "rune.dark") as? Bool
                ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            handle = snapshot.withCString { runeCreate(Unmanaged.passUnretained(metal).toOpaque(), Float(bounds.width), Float(bounds.height), Float(window.backingScaleFactor), dark, $0) }
            if handle == nil {
                failed = true
                let alert = NSAlert(); alert.messageText = "DockShift’s Rune renderer couldn’t start"
                alert.informativeText = "The Metal surface could not be created. Your saved profiles are untouched. Quit and reopen DockShift to try again."
                alert.beginSheetModal(for: window)
                return
            }
            lastJSON = snapshot
        }
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        needsFrames = true
    }
    override func layout() {
        super.layout()
        if let handle { runeResize(handle, Float(bounds.width), Float(bounds.height), Float(window?.backingScaleFactor ?? 2)) }
        needsFrames = true
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }

    private func tick() {
        guard let handle, let window, window.isVisible, !window.isMiniaturized else { return }
        if Date().timeIntervalSince(lastModel) > 0.35 {
            lastModel = Date()
            updateWindowAppearance()
            let json = bridge.snapshot()
            if json != lastJSON { json.withCString { runeUpdate(handle, $0) }; lastJSON = json; needsFrames = true }
        }
        guard needsFrames else { return }
        needsFrames = runeFrame(handle)
        if let p = runeCopy(handle) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: p), forType: .string)
            runeFree(p)
        }
        drainActions(handle)
        refreshAccessibility(handle)
    }
    private func drainActions(_ handle: UnsafeMutableRawPointer) {
        guard let p = runeActions(handle) else { return }; defer { runeFree(p) }
        guard let data = String(cString: p).data(using: .utf8), let actions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !actions.isEmpty else { return }
        // Commands may open a modal AppKit panel. Do that after the Rune frame returns; never
        // reenter Rust's mutable Runtime from a native modal event loop.
        DispatchQueue.main.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            for action in actions {
                if let id = self.bridge.perform(action) { id.withCString { runeSelect(handle, $0) } }
            }
            self.lastModel = .distantPast; self.needsFrames = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func pointer(_ event: NSEvent, _ kind: Int32, _ dy: Float = 0) {
        guard let handle else { return }
        let p = convert(event.locationInWindow, from: nil)
        runePointer(handle, kind, Float(p.x), Float(p.y), dy); needsFrames = true
    }
    override func mouseMoved(with event: NSEvent) { pointer(event, 0) }
    override func mouseEntered(with event: NSEvent) { pointer(event, 0) }
    override func mouseExited(with event: NSEvent) { pointer(event, 4) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, 1) }
    override func mouseDragged(with event: NSEvent) { pointer(event, 0) }
    override func mouseUp(with event: NSEvent) { pointer(event, 2) }
    override func scrollWheel(with event: NSEvent) {
        guard let handle else { return }
        let p = convert(event.locationInWindow, from: nil)
        runeWheel(handle, Float(p.x), Float(p.y), Float(event.scrollingDeltaX), Float(event.scrollingDeltaY))
        needsFrames = true
    }

    override func keyDown(with event: NSEvent) {
        let special: [UInt16: String] = [123: "Left", 124: "Right", 125: "Down", 126: "Up", 51: "Backspace", 117: "Delete", 36: "Return", 48: "Tab", 53: "Escape", 115: "Home", 119: "End"]
        if event.modifierFlags.contains(.command), let key = special[event.keyCode] { sendKey(key, event.modifierFlags); return }
        if event.modifierFlags.contains(.command) { sendKey(event.charactersIgnoringModifiers?.lowercased() ?? "", event.modifierFlags); return }
        interpretKeyEvents([event])
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard event.modifierFlags.contains(.command), ["a", "c", "v", "x", "z"].contains(key) else { return super.performKeyEquivalent(with: event) }
        if key == "v" {
            if let value = NSPasteboard.general.string(forType: .string), let handle { value.withCString { runeText(handle, $0) }; needsFrames = true }
        } else { sendKey(key, event.modifierFlags) }
        return true
    }
    private func sendKey(_ key: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let handle else { return }
        let mods: UInt32 = (flags.contains(.shift) ? 1 : 0) | (flags.contains(.command) ? 2 : 0) | (flags.contains(.option) ? 4 : 0) | (flags.contains(.control) ? 8 : 0)
        key.withCString { runeKey(handle, $0, mods) }; needsFrames = true
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let handle else { return }
        let value = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        value.withCString { runeIME(handle, $0, 0, 0, true) }; marked = ""; needsFrames = true
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let handle else { return }
        marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        let ns = marked as NSString
        let start = ns.substring(to: min(selectedRange.location, ns.length)).utf8.count
        let end = ns.substring(to: min(NSMaxRange(selectedRange), ns.length)).utf8.count
        marked.withCString { runeIME(handle, $0, UInt(start), UInt(end), false) }; needsFrames = true
    }
    func unmarkText() { if !marked.isEmpty { insertText(marked, replacementRange: NSRange(location: NSNotFound, length: 0)) } }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        if let item = accessibilityItems.values.first(where: { $0.isAccessibilityFocused() }) { return item.accessibilityFrame() }
        return window.convertToScreen(convert(bounds, to: nil))
    }
    override func doCommand(by selector: Selector) {
        let commands = ["insertNewline:": "Return", "insertTab:": "Tab", "insertBacktab:": "Tab", "deleteBackward:": "Backspace", "deleteForward:": "Delete", "moveLeft:": "Left", "moveRight:": "Right", "moveUp:": "Up", "moveDown:": "Down", "cancelOperation:": "Escape", "moveToBeginningOfLine:": "Home", "moveToEndOfLine:": "End"]
        if let key = commands[NSStringFromSelector(selector)] { sendKey(key, NSApp.currentEvent?.modifierFlags ?? []) }
    }

    private func refreshAccessibility(_ handle: UnsafeMutableRawPointer) {
        guard let p = runeElements(handle) else { return }; defer { runeFree(p) }
        let json = String(cString: p)
        guard json != lastAccessibility, let bytes = json.data(using: .utf8), let elements = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { return }
        lastAccessibility = json
        var children: [RuneAccessible] = []
        var kept: Set<String> = []
        for element in elements {
            guard let path = element["path"] as? String, let label = element["label"] as? String, !label.isEmpty,
                  let rect = element["rect"] as? [Double], rect.count == 4 else { continue }
            let role = element["role"] as? String ?? "text"
            guard role == "text" || role == "button" || role == "switch" || role == "textbox" else { continue }
            let item = accessibilityItems[path] ?? RuneAccessible()
            item.host = self; item.localRect = NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
            let localRect = item.localRect
            item.frameHandler = { [weak self] in
                guard let self, let window = self.window else { return .zero }
                return window.convertToScreen(self.convert(localRect, to: nil))
            }
            let point = NSPoint(x: item.localRect.midX, y: item.localRect.midY)
            item.pressHandler = { [weak self] in self?.accessibilityPress(point) ?? false }
            item.setAccessibilityParent(self); item.setAccessibilityLabel(label)
            item.setAccessibilityRole(role == "button" ? .button : role == "switch" ? .checkBox : role == "textbox" ? .textField : .staticText)
            item.setAccessibilityEnabled(true)
            item.setAccessibilityIdentifier(element["key"] as? String ?? path)
            item.setAccessibilityFocused(element["focused"] as? Bool ?? false)
            item.setAccessibilityHelp(element["help"] as? String)
            item.setAccessibilityValue(element["value"] is NSNull ? nil : element["value"])
            accessibilityItems[path] = item; children.append(item); kept.insert(path)
        }
        accessibilityItems = accessibilityItems.filter { kept.contains($0.key) }
        setAccessibilityChildren(children)
    }
    func accessibilityPress(_ point: NSPoint) -> Bool {
        guard let handle else { return false }
        window?.makeFirstResponder(self)
        runePointer(handle, 1, Float(point.x), Float(point.y), 0)
        runePointer(handle, 2, Float(point.x), Float(point.y), 0); needsFrames = true
        return true
    }
}

@MainActor
private final class RuneAccessible: NSAccessibilityElement {
    weak var host: RuneHost?
    var localRect = NSRect.zero
    nonisolated(unsafe) var frameHandler: (@MainActor @Sendable () -> NSRect)?
    nonisolated(unsafe) var pressHandler: (@MainActor @Sendable () -> Bool)?
    nonisolated override func accessibilityFrame() -> NSRect {
        guard let frameHandler else { return .zero }
        if Thread.isMainThread { return MainActor.assumeIsolated { frameHandler() } }
        return DispatchQueue.main.sync { frameHandler() }
    }
    nonisolated override func accessibilityPerformPress() -> Bool {
        guard let pressHandler else { return false }
        if Thread.isMainThread { return MainActor.assumeIsolated { pressHandler() } }
        return DispatchQueue.main.sync { pressHandler() }
    }
}
