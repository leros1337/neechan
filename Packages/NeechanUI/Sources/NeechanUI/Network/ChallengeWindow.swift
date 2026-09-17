import NeechanAPI
import NeechanCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Puts the site's browser check over the app, whatever else is showing.
    func browserCheckCover(_ services: AppServices) -> some View {
        modifier(BrowserCheckCover(services: services))
    }
}

/// Shows the browser check in a window of its own, above the app's.
///
/// Not a sheet on the root view, which is where this used to be. SwiftUI will
/// not present a second sheet over one that is already up, and the request most
/// likely to be refused by a gate is the captcha — which is asked for from
/// inside the reply form, itself a sheet. The check was therefore never
/// presented at precisely the moment it was needed: the reader saw "the site
/// wants to check your browser" and no way to answer it.
///
/// The lock screen sits in its own window for the same reason; see `LockWindow`.
private struct BrowserCheckCover: ViewModifier {
    let services: AppServices

    #if os(iOS)
    @State private var host = BrowserCheckWindowHost()

    func body(content: Content) -> some View {
        content
            // The scene the app is drawing into, taken from the view itself
            // rather than by searching the connected scenes, which picks the
            // wrong one when an iPad has two windows open.
            .background(BrowserCheckSceneProbe { scene in host.attach(to: scene) })
            .onChange(of: services.pendingChallengeURL, initial: true) { _, _ in update() }
    }

    private func update() {
        host.update(url: services.pendingChallengeURL, services: services)
    }
    #else
    func body(content: Content) -> some View {
        content
    }
    #endif
}

#if os(iOS)
/// Holds the window the browser check lives in.
@MainActor
@Observable
final class BrowserCheckWindowHost {
    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private weak var scene: UIWindowScene?

    func attach(to scene: UIWindowScene) {
        guard scene !== self.scene else { return }
        self.scene = scene
    }

    /// Built the first time a check is wanted, and let go the moment it is
    /// passed: with no gate in the way the app carries nothing extra.
    func update(url: URL?, services: AppServices) {
        guard let url, let scene else {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil else { return }

        let content = CloudflareChallengeSheet(url: url).environment(services)
        let controller = UIHostingController(rootView: content)
        // Without this, VoiceOver reads straight through the check to whatever
        // is behind it.
        controller.view.accessibilityViewIsModal = true

        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        // Above every sheet the app puts up, and below the lock: a locked app
        // shows nobody a web view.
        window.windowLevel = .alert
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Reports the scene the view is living in, once it has one.
private struct BrowserCheckSceneProbe: UIViewRepresentable {
    var onFound: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onFound = onFound
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onFound = onFound
        view.report()
    }

    /// Read in both places on purpose: there is no window at the first layout.
    final class ProbeView: UIView {
        var onFound: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        func report() {
            guard let scene = window?.windowScene else { return }
            onFound?(scene)
        }
    }
}
#endif
