import UIKit
import PushKit
import AVFoundation

extension Notification.Name {
    static let audioSessionInterruptionEnded = Notification.Name("audioSessionInterruptionEnded")
    static let audioRouteChanged = Notification.Name("audioRouteChanged")
}

class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate {

    private var voipRegistry: PKPushRegistry?
    private var isRecoveringFromInterruption = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Configure audio session for VoIP
        configureAudioSession()

        // Register for audio interruption notifications
        setupAudioInterruptionHandler()

        // Register for VoIP push notifications
        registerForVoIPPush()

        // Request notification permissions
        requestNotificationPermissions()

        return true
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.01)  // 10ms buffer
            try session.setActive(true)  // WICHTIG: Audio-Session aktivieren!

            // Erzwinge Wiedergabe über den Lautsprecher (nicht Telefonhörer)
            try session.overrideOutputAudioPort(.speaker)

            print("Audio session configured and activated successfully")
            print("Audio output route: \(session.currentRoute.outputs.first?.portType.rawValue ?? "unknown")")
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    private func setupAudioInterruptionHandler() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("[Audio] Interruption began (e.g., phone call)")
            isRecoveringFromInterruption = true
            // Audio is automatically paused by the system

        case .ended:
            print("[Audio] Interruption ended")

            // Check if we should resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("[Audio] Resuming audio session after interruption")
                    reactivateAudioSessionAfterInterruption()
                }
            } else {
                // No options provided, try to reactivate anyway
                reactivateAudioSessionAfterInterruption()
            }
            isRecoveringFromInterruption = false

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute
        let outputPort = currentRoute.outputs.first?.portType.rawValue ?? "unknown"
        let inputPort = currentRoute.inputs.first?.portType.rawValue ?? "unknown"
        let sampleRate = session.sampleRate

        switch reason {
        case .oldDeviceUnavailable:
            print("[Audio] Audio device disconnected — input=\(inputPort), output=\(outputPort), sampleRate=\(sampleRate)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioRouteChanged, object: nil)
            }

        case .newDeviceAvailable:
            print("[Audio] New audio device connected — input=\(inputPort), output=\(outputPort), sampleRate=\(sampleRate)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioRouteChanged, object: nil)
            }

        case .categoryChange:
            print("[Audio] Audio category changed")

        default:
            break
        }
    }

    private func reactivateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try session.overrideOutputAudioPort(.speaker)
            print("[Audio] Audio session reactivated successfully")
        } catch {
            print("[Audio] Failed to reactivate audio session: \(error)")
        }
    }

    private func reactivateAudioSessionAfterInterruption() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try session.overrideOutputAudioPort(.speaker)
            print("[Audio] Audio session reactivated after interruption")

            // Notify AudioService to restart audio engine (only after actual interruption)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioSessionInterruptionEnded, object: nil)
            }
        } catch {
            print("[Audio] Failed to reactivate audio session after interruption: \(error)")
        }
    }

    @objc private func handleAppDidBecomeActive() {
        print("[App] Did become active - ensuring audio session is active")
        // Skip if we're recovering from an interruption (handled separately)
        if isRecoveringFromInterruption {
            print("[App] Skipping - already recovering from interruption")
            return
        }
        reactivateAudioSession()
    }

    @objc private func handleAppWillResignActive() {
        print("[App] Will resign active - audio session remains active for background VoIP")
        // Don't deactivate audio session - we want to keep receiving audio in background
    }

    // MARK: - VoIP Push

    private func registerForVoIPPush() {
        voipRegistry = PKPushRegistry(queue: .main)
        voipRegistry?.delegate = self
        voipRegistry?.desiredPushTypes = [.voIP]
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate pushCredentials: PKPushCredentials,
                      for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        print("VoIP Push Token: \(token)")
        // TODO: Send token to server
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        print("Received VoIP push: \(payload.dictionaryPayload)")
        // TODO: Handle incoming alarm notification
        completion()
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        print("VoIP push token invalidated")
    }

    // MARK: - Notifications

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Notification permission granted")
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("APNs Token: \(token)")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }
}
