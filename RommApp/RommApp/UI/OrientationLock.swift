import SwiftUI
import UIKit

/// Pins the app to one orientation while a game is on screen.
///
/// A Game & Watch game plays in its artwork's own orientation and the VMU
/// player in portrait, so each pins it there while it is on screen and
/// the rest of the app rotates freely.
///
/// Locking to a family rather than one exact orientation keeps the 180
/// degree flip working in landscape, which changes nothing about the
/// layout and is how a phone gets its charging cable out of the way.
enum OrientationLock {
    /// What the whole app currently allows. UIKit asks the delegate on
    /// every rotation, so changing this and prodding the scene is enough.
    static var mask: UIInterfaceOrientationMask = .all

    /// Landscape regardless of how the phone is held right now.
    static func lockToLandscape() {
        mask = .landscape
        apply()
    }

    /// Portrait regardless of how the phone is held right now.
    static func lockToPortrait() {
        mask = .portrait
        apply()
    }

    static func unlock() {
        mask = .all
        apply()
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private static func apply() {
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// Exists solely to answer UIKit's orientation question with the mask
/// above. SwiftUI has no view level equivalent of this delegate call.
// UIResponder rather than NSObject: the standard app-delegate shape, the
// one the Xcode template uses.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        QuickAction.register()
        // Recreates the background download session at every launch, so
        // a queue the system carried on with while the app was gone
        // delivers its files now. Apple's page for
        // handleEventsForBackgroundURLSession: at launch the app is not
        // told about transfers still in progress, "you must recreate the
        // session object yourself".
        BackgroundDownloads.shared.prepare()
        GameControllerManager.installRumbleRouting()
        // Cartridge motion sensors. Only wires the route. Nothing starts until a core actually
        // enables a sensor, which today means mGBA and a handful of
        // Game Boy Advance carts.
        LibretroFrontend.setMotionSensingHandler { accelerometer, gyroscope in
            MainActor.assumeIsolated {
                MotionSensor.shared.setEnabled(
                    accelerometer: accelerometer, gyroscope: gyroscope
                )
            }
        }
        return true
    }

    /// The system relaunched the app because its background downloads
    /// finished. The handler is called back once the session has
    /// delivered them; see BackgroundDownloads.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloads.identifier else {
            completionHandler()
            return
        }
        BackgroundDownloads.shared.eventsCompletionHandler = completionHandler
        BackgroundDownloads.shared.prepare()
    }

    /// Names the scene delegate that receives quick action taps; SwiftUI
    /// keeps driving the scene's content exactly as before, this only adds
    /// the delegate alongside it.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role
        )
        // A television, over AirPlay or a cable, gets its own window
        // showing the game and nothing else. Every other scene is the
        // app itself and keeps the quick action delegate it always had.
        // See ExternalDisplay.swift.
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            // Named to match the configuration in Info.plist's scene
            // manifest. The manifest is what makes iOS offer the scene at
            // all; this returns the matching configuration when it does.
            let external = UISceneConfiguration(
                name: "Cabinet External Display", sessionRole: connectingSceneSession.role
            )
            external.delegateClass = ExternalDisplaySceneDelegate.self
            return external
        }
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}
