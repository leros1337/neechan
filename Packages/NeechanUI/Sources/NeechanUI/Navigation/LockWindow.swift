import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Covers the app while it is locked or off screen.
    func appLockCover(_ lock: AppLock) -> some View {
        modifier(AppLockCover(lock: lock))
    }
}

/// Puts the lock screen in a window of its own, above the app's.
///
/// Not an overlay on the root view. SwiftUI draws a sheet and a full-screen
/// cover above the whole hierarchy, and this app has fifteen of them, including
/// the gallery and the reply form: an overlay would have left the picture the
/// reader was looking at on screen, in the switcher, and above the lock. A
/// window is the only thing that reliably sits over all of it.
private struct AppLockCover: ViewModifier {
    let lock: AppLock

    #if os(iOS)
    @State private var host = LockWindowHost()

    func body(content: Content) -> some View {
        content
            // The scene the app is drawing into, taken from the view itself
            // rather than by searching the connected scenes, which picks the
            // wrong one when an iPad has two windows open.
            .background(WindowSceneProbe { scene in host.attach(to: scene) })
            .onChange(of: lock.isCovered, initial: true) { _, _ in update() }
            .onChange(of: lock.isLocked) { _, _ in update() }
    }

    private func update() {
        host.update(isCovered: lock.isCovered, isLocked: lock.isLocked) {
            lock.authenticate()
        }
    }
    #else
    func body(content: Content) -> some View {
        content
    }
    #endif
}

#if os(iOS)
/// Holds the window the lock screen lives in.
@MainActor
@Observable
final class LockWindowHost {
    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private weak var scene: UIWindowScene?
    /// What was last asked for, kept for a scene that turns up afterwards.
    ///
    /// A launch decides it is locked before the view has found its scene, and
    /// from then on nothing about the lock changes until somebody answers. A
    /// request dropped for want of a scene was never made again, and the prompt
    /// ran over the live app.
    @ObservationIgnored private var isCovered = false
    @ObservationIgnored private var isLocked = false
    @ObservationIgnored private var onUnlock: () -> Void = {}

    func attach(to scene: UIWindowScene) {
        guard scene !== self.scene else { return }
        // A window belongs to the scene it was made in, and would go on
        // covering that one rather than the one the app now draws into.
        if let window, window.windowScene !== scene {
            window.isHidden = true
            self.window = nil
        }
        self.scene = scene
        AppLock.log.notice("scene attached, covered: \(self.isCovered), locked: \(self.isLocked)")
        apply()
    }

    func update(isCovered: Bool, isLocked: Bool, onUnlock: @escaping () -> Void) {
        self.isCovered = isCovered
        self.isLocked = isLocked
        self.onUnlock = onUnlock
        apply()
    }

    /// Builds the window the first time it is wanted, and lets it go when it is
    /// not: with the lock off, the app carries nothing extra at all.
    private func apply() {
        guard isCovered else {
            if window != nil { AppLock.log.notice("cover taken down") }
            window?.isHidden = true
            window = nil
            return
        }
        guard let scene else {
            AppLock.log.notice("cover held until the scene is known")
            return
        }

        let content = LockScreenView(isLocked: isLocked, onUnlock: onUnlock)

        if let window, let controller = window.rootViewController as? UIHostingController<LockScreenView> {
            controller.rootView = content
            apply(isLocked: isLocked, to: window)
            return
        }

        let controller = UIHostingController(rootView: content)
        // Without this, VoiceOver reads straight through the cover to the
        // thread behind it.
        controller.view.accessibilityViewIsModal = true
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        apply(isLocked: isLocked, to: window)
        self.window = window
        AppLock.log.notice("cover built, locked: \(self.isLocked)")
    }

    /// A cover over an app nobody is touching takes no touches and is not made
    /// key, which would dismiss the keyboard every time Control Centre opened.
    /// A lock does both, because its button has to be pressable.
    private func apply(isLocked: Bool, to window: UIWindow) {
        window.isUserInteractionEnabled = isLocked
        if isLocked {
            window.makeKeyAndVisible()
        } else {
            window.isHidden = false
        }
    }
}

/// Reports the scene the view is living in, once it has one.
private struct WindowSceneProbe: UIViewRepresentable {
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
