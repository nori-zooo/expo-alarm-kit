import Foundation
import Darwin
#if os(iOS)
import Security
import LocalAuthentication
#endif

/// 「とめる」の操作記録。予約UUIDを再送の識別子に使い、最初の操作時刻を保持する。
struct AlarmStopEvent: Codable, Equatable {
    let id: String
    let occurredAt: Date
}

/// HTTP中はロックを保持しない。別プロセスからの再送はサーバーの主キーで重複排除する。
final class AlarmStopEventStore {
    let root: URL
    init(root: URL) { self.root = root }
    private func transaction<T>(_ operation: (URL) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        let fd = open(root.appendingPathComponent("events.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
        defer { flock(fd, LOCK_UN) }
        return try operation(root)
    }
    func record(alarmId: String, now: Date = Date()) throws -> AlarmStopEvent {
        guard let uuid = UUID(uuidString: alarmId) else { throw CocoaError(.coderInvalidValue) }
        return try transaction { root in
            let url = root.appendingPathComponent(uuid.uuidString.lowercased() + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                return try JSONDecoder().decode(AlarmStopEvent.self, from: Data(contentsOf: url))
            }
            let event = AlarmStopEvent(id: uuid.uuidString.lowercased(), occurredAt: now)
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try JSONEncoder().encode(event).write(to: url, options: options)
            return event
        }
    }
    func pending() throws -> [AlarmStopEvent] {
        try transaction { root in
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(AlarmStopEvent.self, from: Data(contentsOf: $0)) }
                .sorted { $0.occurredAt < $1.occurredAt }
        }
    }
    func acknowledge(_ event: AlarmStopEvent) throws {
        guard UUID(uuidString: event.id) != nil else { throw CocoaError(.coderInvalidValue) }
        try transaction { root in
            let url = root.appendingPathComponent(event.id + ".json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}

#if os(iOS)
/// このソースは本体・停止Intent・AlarmKit forkで共用する。確認APIは呼ばない。
public enum AlarmStopSignal {
    private struct Credentials: Decodable {
        let deviceToken: String
        let functionsURL: String
        let anonKey: String
    }
    private static func store() throws -> AlarmStopEventStore {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HajimariAlarmAppGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return AlarmStopEventStore(root: root.appendingPathComponent("Library/Application Support/AlarmStop-v1"))
    }
    /// 停止Intentだけが呼ぶ。保存失敗/通信失敗が鳴動停止や画面遷移を妨げない。
    public static func record(alarmId: String) async {
        do {
            let store = try store()
            let event = try store.record(alarmId: alarmId)
            try await send(event, store: store)
        } catch { NSLog("[alarm] Stop signal pending or unavailable") }
    }
    /// 起動・前面復帰で再送する。送信成功したイベントだけ端末から消す。
    public static func retryPending() async {
        do {
            let store = try store()
            for event in try store.pending().prefix(8) { try await send(event, store: store) }
        } catch { NSLog("[alarm] Stop signal retry deferred") }
    }
    private static func credentials() throws -> Credentials {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HajimariAlarmKeychainGroup") as? String,
              !group.contains("$(") else { throw CocoaError(.coderInvalidValue) }
        let key = Data("credentials".utf8)
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "hajimari-alarm-sync-v1:no-auth",
            kSecAttrGeneric as String: key, kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: group,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw CocoaError(.fileReadNoPermission) }
        let value = try JSONDecoder().decode(Credentials.self, from: data)
        guard !value.deviceToken.isEmpty, !value.anonKey.isEmpty,
              let url = URLComponents(string: value.functionsURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "functions/v1" else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }
    private static func send(_ event: AlarmStopEvent, store: AlarmStopEventStore) async throws {
        let credentials = try credentials()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: AlarmStopRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: credentials.functionsURL)!.appendingPathComponent("record-activity-signal"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_token": credentials.deviceToken, "signal_type": "alarm_stopped",
            "event_id": event.id, "occurred_at": ISO8601DateFormatter().string(from: event.occurredAt),
        ])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try store.acknowledge(event)
    }
}
private final class AlarmStopRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
