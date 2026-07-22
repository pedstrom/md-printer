import AppKit

@MainActor
public final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
