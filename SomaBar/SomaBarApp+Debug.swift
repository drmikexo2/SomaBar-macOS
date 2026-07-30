import AppKit
import os

#if DEBUG
private let log = Logger(subsystem: "com.somabar", category: "App")

/// Distributed-notification hooks for driving the app from scripts during
/// development (notifyutil / distributed notifications from the CLI).
extension AppDelegate {
    func setupDebugNotifications() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.somabar.debug.playFirst"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let appState = self?.appState, let channel = appState.channels.first else {
                    log.error("DEBUG: no channels loaded")
                    return
                }
                log.error("DEBUG: playing '\(channel.name, privacy: .public)'")
                appState.playChannel(channel)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.somabar.debug.playChannel"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.object as? String
            Task { @MainActor in
                guard let raw,
                      let channel = self?.appState.channels.first(where: { $0.id == raw })
                else {
                    log.error("DEBUG: unknown channel '\(raw ?? "nil", privacy: .public)'")
                    return
                }
                log.error("DEBUG: playing channel \(channel.id, privacy: .public)")
                self?.appState.playChannel(channel)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.somabar.debug.togglePlayPause"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appState.togglePlayPause()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.somabar.debug.stop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appState.audioPlayer.stop()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.somabar.debug.openSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showSettingsWindow() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.somabar.debug.openHistory"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showHistoryWindow() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.somabar.debug.toggleArt"),
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("debugToggleArt"), object: nil)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.somabar.debug.togglePanel"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.togglePanel(nil) }
        }

        log.error("DEBUG: notification handlers registered")
    }
}
#else
extension AppDelegate {
    func setupDebugNotifications() {}
}
#endif
