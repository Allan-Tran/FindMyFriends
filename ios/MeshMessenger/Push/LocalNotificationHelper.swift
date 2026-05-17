import UserNotifications

@MainActor
enum LocalNotificationHelper {
    static var suppressRelayNotifications = false
    static func postGroupChat(from username: String, preview: String, groupName: String, groupId: String) {
        guard !suppressRelayNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(username) in \(groupName)"
        content.body = formatted(preview)
        content.sound = .default
        content.userInfo = ["groupId": groupId]
        schedule(content, id: "chat-\(groupId)-\(UUID().uuidString)")
    }

    static func postDMChat(from username: String, preview: String, dmId: String) {
        guard !suppressRelayNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = username
        content.body = formatted(preview)
        content.sound = .default
        content.userInfo = ["dmId": dmId]
        schedule(content, id: "dm-\(dmId)-\(UUID().uuidString)")
    }

    static func postPinAdded(by username: String, in groupName: String, groupId: String) {
        guard !suppressRelayNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(username) added a pin"
        content.body = "New pin in \(groupName)"
        content.sound = .default
        content.userInfo = ["groupId": groupId, "kind": "pin"]
        schedule(content, id: "pin-\(groupId)-\(UUID().uuidString)")
    }

    private static func formatted(_ raw: String) -> String {
        if raw.hasPrefix("img:") || raw.hasPrefix("imgdata:") { return "📷 Photo" }
        return raw.count > 80 ? String(raw.prefix(80)) + "…" : raw
    }

    private static func schedule(_ content: UNMutableNotificationContent, id: String) {
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
