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
    /// Diagnostic output is intentionally limited to phase/result, OS status, HTTP status,
    /// and a production/staging/other destination label. Never log credentials or payloads.
    private static func logError(_ phase: String, _ error: Error) {
        let value = error as NSError
        NSLog("[alarm-stop] phase=\(phase) outcome=error domain=\(value.domain) code=\(value.code)")
    }
    /// 停止Intentだけが呼ぶ。保存失敗/通信失敗が鳴動停止や画面遷移を妨げない。
    public static func record(alarmId: String) async {
        NSLog("[alarm-stop] phase=signal.record outcome=started signal=alarm_stopped")
        let eventStore: AlarmStopEventStore
        do { eventStore = try store() }
        catch { logError("event_store.open", error); return }

        let event: AlarmStopEvent
        do {
            event = try eventStore.record(alarmId: alarmId)
            NSLog("[alarm-stop] phase=event.persist outcome=success")
        } catch { logError("event.persist", error); return }

        do {
            try await send(event, store: eventStore)
            NSLog("[alarm-stop] phase=signal.record outcome=acknowledged")
        } catch {
            logError("signal.send", error)
            NSLog("[alarm-stop] phase=event.persist outcome=retained")
        }
    }
    /// 起動・前面復帰で再送する。送信成功したイベントだけ端末から消す。
    public static func retryPending() async {
        NSLog("[alarm-stop] phase=retry.start outcome=started")
        let eventStore: AlarmStopEventStore
        do { eventStore = try store() }
        catch { logError("retry.event_store.open", error); return }

        let events: [AlarmStopEvent]
        do { events = try eventStore.pending() }
        catch { logError("retry.queue.read", error); return }
        NSLog("[alarm-stop] phase=retry.queue pending_count=\(events.count)")

        for event in events.prefix(8) {
            do {
                try await send(event, store: eventStore)
                NSLog("[alarm-stop] phase=retry.send outcome=acknowledged")
            } catch {
                logError("retry.send", error)
                return
            }
        }
    }
    private static func credentials() throws -> Credentials {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HajimariAlarmKeychainGroup") as? String,
              !group.contains("$(") else {
            NSLog("[alarm-stop] phase=credentials.config outcome=invalid_keychain_group")
            throw CocoaError(.coderInvalidValue)
        }
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            NSLog("[alarm-stop] phase=credentials.keychain outcome=error os_status=\(status)")
            throw CocoaError(.fileReadNoPermission)
        }
        guard let data = result as? Data else {
            NSLog("[alarm-stop] phase=credentials.keychain outcome=error result=invalid_data")
            throw CocoaError(.fileReadNoPermission)
        }
        let value: Credentials
        do { value = try JSONDecoder().decode(Credentials.self, from: data) }
        catch { logError("credentials.decode", error); throw error }
        guard !value.deviceToken.isEmpty, !value.anonKey.isEmpty,
              let url = URLComponents(string: value.functionsURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "functions/v1" else {
            NSLog("[alarm-stop] phase=credentials.validate outcome=invalid")
            throw CocoaError(.coderInvalidValue)
        }
        NSLog("[alarm-stop] phase=credentials.keychain outcome=success")
        return value
    }
    private static func targetEnvironment(_ functionsURL: String) -> String {
        guard let host = URLComponents(string: functionsURL)?.host?.lowercased() else { return "invalid" }
        switch host {
        case "sujflccmacbrblfdnnto.supabase.co": return "production"
        case "gtpwdfogxolrgungcyk.supabase.co": return "staging"
        default: return "other"
        }
    }
    private static func send(_ event: AlarmStopEvent, store: AlarmStopEventStore) async throws {
        let credentials = try credentials()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: AlarmStopRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let baseURL = URL(string: credentials.functionsURL) else {
            NSLog("[alarm-stop] phase=http.request outcome=error reason=invalid_functions_url")
            throw URLError(.badURL)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("record-activity-signal"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.anonKey, forHTTPHeaderField: "apikey")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_token": credentials.deviceToken, "signal_type": "alarm_stopped",
                "event_id": event.id, "occurred_at": ISO8601DateFormatter().string(from: event.occurredAt),
            ])
        } catch { logError("http.request.encode", error); throw error }

        NSLog("[alarm-stop] phase=http.request outcome=started method=POST endpoint=record-activity-signal target=\(targetEnvironment(credentials.functionsURL))")
        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            response = result.1
        } catch { logError("http.transport", error); throw error }
        guard let http = response as? HTTPURLResponse else {
            NSLog("[alarm-stop] phase=http.response outcome=error reason=invalid_response")
            throw URLError(.badServerResponse)
        }
        NSLog("[alarm-stop] phase=http.response status=\(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        do { try store.acknowledge(event) }
        catch { logError("event.acknowledge", error); throw error }
        NSLog("[alarm-stop] phase=event.acknowledge outcome=success")
    }
}
private final class AlarmStopRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
