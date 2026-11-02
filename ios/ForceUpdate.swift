// ForceUpdate.swift - Vibeloy force update client for iOS 15+. Copy this file into your Xcode target.
//
// Install: nothing to install, no dependencies.
// SwiftUI: WindowGroup { ContentView().forceUpdate() }
// UIKit:   override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); ForceUpdate.check(from: self) }
// Set your manifest URL in ForceUpdate.defaultManifestURL below, or pass manifestURL: to either one.
//
// Fails open: on a network, timeout or parse problem nothing is shown. This code never throws.

import SwiftUI
import UIKit

public enum ForceUpdate {
    public static let defaultManifestURL = "https://YOUR-SLUG.vibeloy.dev/version.json"

    /// Checks now, and again every time the app becomes active while `viewController` is alive.
    /// Presents above whatever `viewController` is currently presenting.
    @MainActor
    public static func check(from viewController: UIViewController, manifestURL: String = defaultManifestURL) {
        Prompter.shared.watch(host: viewController, manifestURL: manifestURL)
    }

    /// Returns a negative number, zero or a positive number when `a` is below, equal to or above `b`.
    /// `1.2.3+45` and `1.2.3-debug` compare as `1.2.3`, `1.2` as `1.2.0`, a non-numeric part as 0.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let left = versionParts(a)
        let right = versionParts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    private static func versionParts(_ version: String) -> [Int] {
        let core = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0 != "+" && $0 != "-" }
        return core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }

    // MARK: - Manifest

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let ios: Platform?
        let message: Message?
    }

    private struct Platform: Decodable {
        let minVersion: String?
        let latestVersion: String?
        let storeUrl: String?
    }

    private struct Message: Decodable {
        let tr: String?
        let en: String?
    }

    /// The parts of the manifest this client uses, with blank strings turned into nil.
    private struct Policy {
        let minVersion: String?
        let latestVersion: String?
        let storeURL: URL?
        let messageTr: String?
        let messageEn: String?
    }

    /// Nil means the check failed: non-200, timeout, bad JSON, other schemaVersion or no `ios` block.
    private static func fetchPolicy(_ urlString: String) async -> Policy? {
        guard let url = URL(string: urlString) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schemaVersion == 1, let block = manifest.ios else { return nil }
            return Policy(
                minVersion: clean(block.minVersion),
                latestVersion: clean(block.latestVersion),
                storeURL: clean(block.storeUrl).flatMap { URL(string: $0) },
                messageTr: clean(manifest.message?.tr),
                messageEn: clean(manifest.message?.en)
            )
        } catch {
            return nil
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Decision

    private enum Kind { case force, soft }

    private static func decide(current: String, policy: Policy) -> Kind? {
        if let min = policy.minVersion, compareVersions(current, min) < 0 { return .force }
        if let latest = policy.latestVersion, compareVersions(current, latest) < 0 {
            return isDismissed(latest) ? nil : .soft
        }
        return nil
    }

    private static let dismissedKey = "vibeloy_force_update_dismissed"
    private static let laterWindow: TimeInterval = 24 * 60 * 60

    private static func isDismissed(_ latest: String) -> Bool {
        guard
            let saved = UserDefaults.standard.dictionary(forKey: dismissedKey),
            saved["version"] as? String == latest,
            let dismissedAt = saved["dismissedAt"] as? TimeInterval
        else { return false }
        let age = Date().timeIntervalSince1970 - dismissedAt
        return age >= 0 && age < laterWindow
    }

    private static func saveDismissal(_ latest: String?) {
        guard let latest else { return }
        UserDefaults.standard.set(
            ["version": latest, "dismissedAt": Date().timeIntervalSince1970],
            forKey: dismissedKey
        )
    }

    // MARK: - Text

    private struct Strings {
        let title: String
        let body: String
        let update: String
        let later: String

        init(kind: Kind, policy: Policy) {
            // preferredLanguages is the device order, whatever localizations the app itself ships.
            let turkish = Locale.preferredLanguages.first?.lowercased().hasPrefix("tr") ?? false
            let force = kind == .force
            title = force
                ? (turkish ? "Güncelleme gerekli" : "Update required")
                : (turkish ? "Yeni sürüm var" : "New version available")
            let defaultBody = force
                ? (turkish ? "Devam etmek için uygulamayı güncellemeniz gerekiyor." : "Please update the app to continue.")
                : (turkish ? "Uygulamanın yeni bir sürümü hazır." : "A new version of the app is available.")
            body = (turkish ? policy.messageTr : policy.messageEn)
                ?? (turkish ? policy.messageEn : policy.messageTr)
                ?? defaultBody
            update = turkish ? "Güncelle" : "Update"
            later = turkish ? "Sonra" : "Later"
        }
    }

    // MARK: - Presentation

    @MainActor
    fileprivate final class Prompter {
        static let shared = Prompter()

        private var isChecking = false
        private var observer: NSObjectProtocol?
        private weak var watchedHost: UIViewController?
        private var watchedURL = ForceUpdate.defaultManifestURL
        private weak var alert: UIAlertController?
        private var alertKind: Kind?

        /// UIKit entry point. Has no scenePhase to observe, so it listens for didBecomeActive itself.
        func watch(host: UIViewController, manifestURL: String) {
            watchedHost = host
            watchedURL = manifestURL
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let host = self.watchedHost else { return }
                        self.check(manifestURL: self.watchedURL) { host }
                    }
                }
            }
            check(manifestURL: manifestURL) { [weak host] in host }
        }

        func check(manifestURL: String, host: @escaping @MainActor () -> UIViewController?) {
            guard !isChecking else { return }
            guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                  !current.isEmpty
            else { return }
            isChecking = true
            Task { @MainActor in
                defer { isChecking = false }
                // A failed check leaves any open alert as it is.
                guard let policy = await ForceUpdate.fetchPolicy(manifestURL) else { return }
                apply(decide(current: current, policy: policy), policy: policy, host: host)
            }
        }

        private var alertIsVisible: Bool {
            guard let alert else { return false }
            return alert.presentingViewController != nil && !alert.isBeingDismissed
        }

        private func apply(_ kind: Kind?, policy: Policy, host: @escaping @MainActor () -> UIViewController?) {
            if alertIsVisible {
                if alertKind == kind { return } // Already on screen: never stack a second alert.
                alert?.dismiss(animated: false)
            }
            alert = nil
            alertKind = nil
            guard let kind else { return }
            present(kind, policy: policy, host: host)
        }

        private func present(_ kind: Kind, policy: Policy, host: @escaping @MainActor () -> UIViewController?) {
            guard !alertIsVisible, let top = Self.topmost(from: host()) else { return }
            // An alert that is still animating away blocks a new one, so try again shortly.
            if top.isBeingDismissed {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self?.present(kind, policy: policy, host: host)
                }
                return
            }

            let text = Strings(kind: kind, policy: policy)
            let controller = UIAlertController(title: text.title, message: text.body, preferredStyle: .alert)
            if let storeURL = policy.storeURL {
                controller.addAction(UIAlertAction(title: text.update, style: .default) { [weak self] _ in
                    UIApplication.shared.open(storeURL)
                    // UIKit closes an alert on any button tap, so the force alert has to come back.
                    if kind == .force { self?.present(kind, policy: policy, host: host) }
                })
            }
            if kind == .soft {
                controller.addAction(UIAlertAction(title: text.later, style: .cancel) { _ in
                    ForceUpdate.saveDismissal(policy.latestVersion)
                })
            }
            alert = controller
            alertKind = kind
            top.present(controller, animated: true)
        }

        /// Walks up to the controller that can present right now. A host that left the window falls back to
        /// the active scene's root.
        private static func topmost(from host: UIViewController?) -> UIViewController? {
            var top = host?.viewIfLoaded?.window != nil ? host : activeRoot()
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }

        private static func activeRoot() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
            return window?.rootViewController
        }
    }
}

// MARK: - SwiftUI

public extension View {
    /// Checks when the scene becomes active: on launch and after returning from the store.
    func forceUpdate(manifestURL: String = ForceUpdate.defaultManifestURL) -> some View {
        modifier(ForceUpdateModifier(manifestURL: manifestURL))
    }
}

private struct ForceUpdateModifier: ViewModifier {
    let manifestURL: String
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            ForceUpdate.Prompter.shared.check(manifestURL: manifestURL) { nil }
        }
    }
}
