import AppKit
import BeatRGBKit
import SwiftUI

@main
struct BeatRGBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("BeatRGB", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 720)
        // In background mode BeatRGB starts with no window, only its menu bar icon.
        .defaultLaunchBehavior(model.prefs.openInBackground ? .suppressed : .presented)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(model.isSyncing ? "Stop Sync" : "Start Sync") { model.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            Image(systemName: model.isSyncing ? "light.beacon.max.fill" : "light.beacon.min")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.applyDockPolicy() }
    }

    /// Closing the window keeps BeatRGB running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // Restore lighting and tear down the audio tap before quitting (bounded wait).
            var finished = false
            AppModel.shared.shutdown { finished = true; NSApp.reply(toApplicationShouldTerminate: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !finished { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
}
