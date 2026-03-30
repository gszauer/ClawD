import Foundation
import UserNotifications

/// Manages desktop notifications via UNUserNotificationCenter.
final class NotificationService: @unchecked Sendable {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private var authorized = false

    private init() {
        requestAuthorization()
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            self.authorized = granted
            if let error {
                print("[Notification] Authorization error: \(error)")
            }
        }
    }

    func send(title: String, body: String) {
        guard authorized else {
            print("[Notification] Not authorized: \(title): \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        center.add(request) { error in
            if let error {
                print("[Notification] Delivery error: \(error)")
            }
        }
    }
}
