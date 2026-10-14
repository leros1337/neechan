import Foundation
@testable import NeechanUI
import SwiftUI
import Testing
import UIKit

/// The window the lock screen lives in.
///
/// Hosted in the app on the simulator, because what is being pinned is the
/// order a launch does things in: the lock had decided it was locked before the
/// view had found its scene, the one request for the cover was thrown away, and
/// nothing ever asked again. Face ID then ran over a live app, and a cancelled
/// prompt left it usable.
@Suite("App lock cover")
@MainActor
struct AppLockCoverTests {
    @Test("a cover asked for before the scene is known goes up when it is")
    func requestOutlivesMissingScene() throws {
        let scene = try windowScene()
        let host = LockWindowHost()
        defer { host.update(isCovered: false, isLocked: false) {} }

        host.update(isCovered: true, isLocked: true) {}
        #expect(lockWindow(in: scene) == nil, "there is nowhere to put it yet")

        host.attach(to: scene)

        let cover = try #require(lockWindow(in: scene))
        #expect(cover.isUserInteractionEnabled, "a lock has to take the touches")
    }

    @Test("a launch that is already locked, and stays locked, is covered")
    func settledLockIsCovered() async throws {
        let scene = try windowScene()
        let lock = AppLock(isEnabled: true, authenticator: CancellingAuthenticator())
        // Settled before any view exists, the way a launch settles it: asked,
        // cancelled, and nothing about the lock changes again.
        lock.sceneBecameActive()
        try await settle()
        #expect(lock.isLocked)

        let window = host(Color.red.appLockCover(lock), in: scene)
        defer { window.isHidden = true }
        try await settle()

        let cover = try #require(lockWindow(in: scene))
        #expect(cover.isUserInteractionEnabled)

        lock.setEnabled(false)
        try await settle()
        #expect(lockWindow(in: scene) == nil)
    }

    @Test("with the lock off nothing is put over the app")
    func disabledPutsNothingUp() async throws {
        let scene = try windowScene()
        let lock = AppLock(isEnabled: false, authenticator: CancellingAuthenticator())
        lock.sceneBecameActive()

        let window = host(Color.red.appLockCover(lock), in: scene)
        defer { window.isHidden = true }
        try await settle()

        #expect(lockWindow(in: scene) == nil)
    }

    private func windowScene() throws -> UIWindowScene {
        try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
    }

    /// The lock's window, if one is showing.
    private func lockWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first { window in
            !window.isHidden && window.rootViewController is UIHostingController<LockScreenView>
        }
    }

    private func host(_ view: some View, in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    /// Long enough for the attempt to come back and the view to draw.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }
}

/// A face that is never recognised: every attempt comes back cancelled.
private struct CancellingAuthenticator: DeviceAuthenticator {
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> AuthenticationOutcome { .cancelled }
    func cancel() {}
}
