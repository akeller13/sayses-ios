import UIKit
import PushKit
import AVFoundation

class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate {

    private var voipRegistry: PKPushRegistry?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Configure audio session for VoIP
        configureAudioSession()

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
            print("Audio session configured and activated successfully")
        } catch {
            print("Failed to configure audio session: \(error)")
        }
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
