import Combine
import Foundation
import Sparkle
import SwiftUI
import VQMetrixCore

@MainActor
final class AppUpdates: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    private let controller: SPUStandardUpdaterController?

    init() {
        // A raw SwiftPM executable has no updater configuration or installable app bundle.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
    func setAutomaticallyChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    var isAvailable: Bool { controller != nil }
}

struct UpdateCommands: View {
    @ObservedObject var updates: AppUpdates
    let language: AppLanguage

    var body: some View {
        Button(language.text("Check for Updates…"), action: updates.checkForUpdates)
            .disabled(!updates.canCheckForUpdates)
        Toggle(language.text("Automatically check for updates"), isOn: Binding(
            get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }
        )).disabled(!updates.isAvailable)
    }
}
