// Log.swift — DockShift
// Unified-logging categories. Stream with:
//   log stream --level debug --predicate 'subsystem == "com.quentinsteinke.DockShift"'
import os

enum Log {
    static let subsystem = "com.quentinsteinke.DockShift"
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let dock = Logger(subsystem: subsystem, category: "dock")
    static let wallpaper = Logger(subsystem: subsystem, category: "wallpaper")
    static let focus = Logger(subsystem: subsystem, category: "focus")
    static let spaces = Logger(subsystem: subsystem, category: "spaces")
    static let store = Logger(subsystem: subsystem, category: "store")
}
