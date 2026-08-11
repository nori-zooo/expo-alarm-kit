import ExpoModulesCore
import AlarmKit
import ActivityKit
import AppIntents
import SwiftUI

// MARK: - Storage Keys
private let alarmKeyPrefix = "ExpoAlarmKit.alarm:"
private let launchAppKeyPrefix = "ExpoAlarmKit.launchApp:"

// MARK: - App Group Storage Manager
// anshin-platform patch (#145): クラスごと iOS 26 ゲートを外す。Storage は UserDefaults しか
// 使わず iOS 26 型を参照しないため un-gate して全 iOS で参照可能にする（ExpoModulesProvider が
// 無条件参照するため）。
public class ExpoAlarmKitStorage {
    public static var appGroupIdentifier: String? = nil
    
    public static var sharedDefaults: UserDefaults? {
        guard let groupId = appGroupIdentifier else {
            print("[ExpoAlarmKit] Warning: App Group not configured. Call configure() first.")
            return nil
        }
        return UserDefaults(suiteName: groupId)
    }
    
    public static func setAlarm(id: String, value: Double) {
        sharedDefaults?.set(value, forKey: alarmKeyPrefix + id)
    }
    
    public static func removeAlarm(id: String) {
        sharedDefaults?.removeObject(forKey: alarmKeyPrefix + id)
    }
    
    public static func getAllAlarmIds() -> [String] {
        guard let defaults = sharedDefaults?.dictionaryRepresentation() else { return [] }
        var alarmIds: [String] = []
        for key in defaults.keys {
            if key.hasPrefix(alarmKeyPrefix) {
                let alarmId = String(key.dropFirst(alarmKeyPrefix.count))
                alarmIds.append(alarmId)
            }
        }
        return alarmIds
    }
    
    public static func clearAllAlarms() {
        guard let defaults = sharedDefaults?.dictionaryRepresentation() else { return }
        for key in defaults.keys {
            if key.hasPrefix(alarmKeyPrefix) {
                sharedDefaults?.removeObject(forKey: key)
            }
        }
    }
    
    public static func setLaunchAppOnDismiss(alarmId: String, value: Bool) {
        sharedDefaults?.set(value, forKey: launchAppKeyPrefix + alarmId)
    }
    
    public static func getLaunchAppOnDismiss(alarmId: String) -> Bool {
        return sharedDefaults?.bool(forKey: launchAppKeyPrefix + alarmId) ?? false
    }
    
    public static func removeLaunchAppOnDismiss(alarmId: String) {
        sharedDefaults?.removeObject(forKey: launchAppKeyPrefix + alarmId)
    }
}

// MARK: - Record Structs for Expo Module
// 注: iOS 26 型を参照しないプリミティブのみなので @available ゲートを付けない
// （ExpoModulesProvider.swift が deployment target 16.4 で無条件参照するため・#145）。
struct ScheduleAlarmOptions: Record {
    @Field var id: String
    @Field var epochSeconds: Double
    @Field var title: String
    @Field var soundName: String?
    @Field var launchAppOnDismiss: Bool?
    @Field var dismissPayload: String?
    @Field var stopButtonLabel: String?
    @Field var stopButtonColor: String?
    @Field var tintColor: String?
}

// MARK: - Helper Functions
private func colorFromHex(_ hex: String) -> Color {
    var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
    
    var rgb: UInt64 = 0
    Scanner(string: hexSanitized).scanHexInt64(&rgb)
    
    let r = Double((rgb & 0xFF0000) >> 16) / 255.0
    let g = Double((rgb & 0x00FF00) >> 8) / 255.0
    let b = Double(rgb & 0x0000FF) / 255.0
    
    return Color(red: r, green: g, blue: b)
}

private func buildLaunchPayload(alarmId: String, payload: String?) -> [String: Any] {
    return [
        "alarmId": alarmId,
        "payload": payload ?? NSNull()
    ]
}

// MARK: - App Intent for Alarm Dismissal (No App Launch)
@available(iOS 26.0, *)
public struct AlarmDismissIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Dismiss Alarm"
    public static var description = IntentDescription("Handles alarm dismissal")
    public static var openAppWhenRun: Bool = false
    
    @Parameter(title: "alarmId")
    public var alarmId: String
    
    @Parameter(title: "payload")
    public var payload: String?
    
    public init() {}
    
    public init(alarmId: String, payload: String? = nil) {
        self.alarmId = alarmId
        self.payload = payload
    }
    
    public func perform() async throws -> some IntentResult {
        // anshin-platform patch (#244): AlarmKit の鳴動を止めるのは **アプリが提供する stopIntent の責務**
        // （Apple の AlarmKit サンプルも stopIntent 内で stop(id:) を呼ぶ）。0.1.11 はここで
        // payload 保存と App Group 掃除しかしておらず、「とめる」を押しても鳴り続けた。
        if let uuid = UUID(uuidString: self.alarmId) {
            try? AlarmManager.shared.stop(id: uuid)
        }

        // Store payload for JS to retrieve
        ExpoAlarmKitModule.launchPayload = buildLaunchPayload(alarmId: self.alarmId, payload: self.payload)

        // Clean up App Group storage
        ExpoAlarmKitStorage.removeAlarm(id: self.alarmId)
        ExpoAlarmKitStorage.removeLaunchAppOnDismiss(alarmId: self.alarmId)

        return .result()
    }
}

// MARK: - App Intent for Alarm Dismissal (With App Launch)
@available(iOS 26.0, *)
public struct AlarmDismissIntentWithLaunch: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Dismiss Alarm"
    public static var description = IntentDescription("Handles alarm dismissal and opens app")
    public static var openAppWhenRun: Bool = true
    
    @Parameter(title: "alarmId")
    public var alarmId: String
    
    @Parameter(title: "payload")
    public var payload: String?
    
    public init() {}
    
    public init(alarmId: String, payload: String? = nil) {
        self.alarmId = alarmId
        self.payload = payload
    }
    
    public func perform() async throws -> some IntentResult {
        // anshin-platform patch (#244): 上の AlarmDismissIntent と同じ理由で、まず鳴動を止める。
        // launchAppOnDismiss=true（はじまりの刻が使う経路）はこちらが呼ばれる。
        if let uuid = UUID(uuidString: self.alarmId) {
            try? AlarmManager.shared.stop(id: uuid)
        }

        // Store payload for JS to retrieve
        ExpoAlarmKitModule.launchPayload = buildLaunchPayload(alarmId: self.alarmId, payload: self.payload)

        // Clean up App Group storage
        ExpoAlarmKitStorage.removeAlarm(id: self.alarmId)
        ExpoAlarmKitStorage.removeLaunchAppOnDismiss(alarmId: self.alarmId)

        return .result()
    }
}

// MARK: - Expo Module
// anshin-platform patch (#145): クラスごと iOS 26 ゲートを外す。これで ExpoModulesProvider.swift
// の無条件参照（deployment target 16.4）が通る。AlarmKit を使う各 AsyncFunction の本体先頭で
// `guard #available(iOS 26.0, *)` し、iOS<26 では早期 return（JS がローカル通知へフォールバック）。
public class ExpoAlarmKitModule: Module {
    // Static payload for app launch detection
    public static var launchPayload: [String: Any]? = nil
    
    public func definition() -> ModuleDefinition {
        Name("ExpoAlarmKit")
        
        // MARK: - Configure App Group
        Function("configure") { (appGroupIdentifier: String) -> Bool in
            ExpoAlarmKitStorage.appGroupIdentifier = appGroupIdentifier
            // Verify the app group is accessible
            if ExpoAlarmKitStorage.sharedDefaults != nil {
                print("[ExpoAlarmKit] Configured with App Group: \(appGroupIdentifier)")
                return true
            } else {
                print("[ExpoAlarmKit] Failed to configure App Group: \(appGroupIdentifier)")
                return false
            }
        }
        
        // MARK: - Request Authorization
        AsyncFunction("requestAuthorization") { () -> String in
            // anshin-platform patch (#145): iOS<26 は AlarmKit 不在。denied を返す（JS は非 authorized
            // をフォールバック扱い）。guard 以降は iOS 26 可用性が伝播する。
            guard #available(iOS 26.0, *) else { return "denied" }
            let status = AlarmManager.shared.authorizationState
            switch status {
            case .authorized:
                return "authorized"
            case .denied:
                do {
                    let newStatus = try await AlarmManager.shared.requestAuthorization()
                    switch newStatus {
                    case .authorized:
                        return "authorized"
                    case .denied:
                        return "denied"
                    case .notDetermined:
                        return "notDetermined"
                    @unknown default:
                        return "notDetermined"
                    }
                } catch {
                    return "denied"
                }
            case .notDetermined:
                do {
                    let newStatus = try await AlarmManager.shared.requestAuthorization()
                    switch newStatus {
                    case .authorized:
                        return "authorized"
                    case .denied:
                        return "denied"
                    case .notDetermined:
                        return "notDetermined"
                    @unknown default:
                        return "notDetermined"
                    }
                } catch {
                    return "denied"
                }
            @unknown default:
                return "notDetermined"
            }
        }
        
        // MARK: - Generate UUID
        Function("generateUUID") { () -> String in
            return UUID().uuidString
        }
        
        // MARK: - Schedule One-Time Alarm
        AsyncFunction("scheduleAlarm") { (options: ScheduleAlarmOptions) async throws -> Bool in
            // anshin-platform patch (#145): iOS<26 は false を返し JS をローカル通知へフォールバックさせる。
            guard #available(iOS 26.0, *) else { return false }
            struct Meta: AlarmMetadata {}
            
            let date = Date(timeIntervalSince1970: options.epochSeconds)
            guard let uuid = UUID(uuidString: options.id) else {
                print("[ExpoAlarmKit] Invalid UUID string: \(options.id)")
                return false
            }
            let launchAppOnDismiss = options.launchAppOnDismiss ?? false

            // Create stop button
            let stopLabel = options.stopButtonLabel ?? "Stop"
            let stopColor = options.stopButtonColor != nil ? colorFromHex(options.stopButtonColor!) : Color.white
            let stopButton = AlarmButton(
                text: LocalizedStringResource(stringLiteral: stopLabel),
                textColor: stopColor,
                systemImageName: "stop.circle"
            )

            // はじまりの刻 (#145/#262): アラートは「とめる」1アクションのみ。snooze ボタンは持たない。
            // upstream は doSnoozeIntent=false でも secondaryIntent=nil のまま snooze ボタンを表示し、
            // 「押しても何も起きない壊れたボタン」になっていた。fork では snooze を概念ごと削除した。
            let presentation = AlarmPresentation(
                alert: AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: options.title),
                    stopButton: stopButton
                )
            )

            // Create attributes
            let alarmTintColor = options.tintColor != nil ? colorFromHex(options.tintColor!) : Color.blue
            let attributes = AlarmAttributes<Meta>(
                presentation: presentation,
                metadata: Meta(),
                tintColor: alarmTintColor
            )
            
            // Determine sound
            let alarmSound: AlertConfiguration.AlertSound
            if let soundName = options.soundName, !soundName.isEmpty {
                alarmSound = .named(soundName)
            } else {
                alarmSound = .default
            }
            
            // Choose the appropriate intent based on launchAppOnDismiss
            // AlarmDismissIntentWithLaunch sets openAppWhenRun=true, AlarmDismissIntent sets it to false
            let stopIntent: any LiveActivityIntent = launchAppOnDismiss
                ? AlarmDismissIntentWithLaunch(alarmId: options.id, payload: options.dismissPayload)
                : AlarmDismissIntent(alarmId: options.id, payload: options.dismissPayload)
            
            // Create configuration
            //
            // ⚠️ countdownDuration は**渡さない**（#262・最重要）。AlarmKit の `postAlert` は
            //    「アラートが終わったあと、この秒数後にもう一度アラートする」という指定で、
            //    upstream は snooze の有無に関わらず 9 分（`9 * 60`）を無条件にハードコードして
            //    いた。その結果、「とめる」を押さず放置すると 15 分の鳴動が OS に打ち切られた
            //    あと、**9 分ごとに無音の全画面アラートが繰り返される**（2026-08-11 実機で確認:
            //    10:33 発火 → 11:09 = +36分 = 9分×4 / 11:18 = +45分 = 9分×5）。
            //    snooze を持たない以上この指定自体が不要なので、パラメータごと省略する。
            // ⚠️ secondaryIntent も渡さない（snooze ボタンが無いため対になる intent も不要）。
            let config = AlarmManager.AlarmConfiguration<Meta>(
                schedule: .fixed(date),
                attributes: attributes,
                stopIntent: stopIntent,
                sound: alarmSound
            )
            
            do {
                try await AlarmManager.shared.schedule(id: uuid, configuration: config)
                // Store alarm metadata in App Group
                ExpoAlarmKitStorage.setAlarm(id: options.id, value: options.epochSeconds)
                return true
            } catch {
                print("[ExpoAlarmKit] Failed to schedule alarm: \(error)")
                return false
            }
        }
        
        // MARK: - Cancel Alarm
        AsyncFunction("cancelAlarm") { (id: String) -> Bool in
            // anshin-platform patch (#145): iOS<26 は AlarmKit 不在。false を返す。
            guard #available(iOS 26.0, *) else { return false }
            guard let uuid = UUID(uuidString: id) else {
                print("[ExpoAlarmKit] Invalid UUID string: \(id)")
                return false
            }
            
            do {
                try AlarmManager.shared.cancel(id: uuid)
                // Clean up App Group storage
                ExpoAlarmKitStorage.removeAlarm(id: id)
                ExpoAlarmKitStorage.removeLaunchAppOnDismiss(alarmId: id)
                return true
            } catch {
                print("[ExpoAlarmKit] Failed to cancel alarm: \(error)")
                return false
            }
        }
        
        // MARK: - Stop Alerting Alarms
        // anshin-platform patch (#244): 「いま鳴っている」アラームだけを止める復旧口。
        // AlarmManager.alarms の state == .alerting を stop(id:) する。App Group 記録
        // （getAllAlarms）ではなく OS の状態を直接見るため、レジストリから引けなくなった
        // 孤児予約（#185）や、回転でアラート UI だけ破棄された鳴動（#198）も止められる。
        // 予約済み（.scheduled）には触れないので、未来のアラームは消えない。
        // 戻り値は止めた件数（iOS<26 は 0）。
        AsyncFunction("stopAlertingAlarms") { () -> Int in
            guard #available(iOS 26.0, *) else { return 0 }
            var stopped = 0
            for alarm in AlarmManager.shared.alarms where alarm.state == .alerting {
                do {
                    try AlarmManager.shared.stop(id: alarm.id)
                    ExpoAlarmKitStorage.removeAlarm(id: alarm.id.uuidString)
                    ExpoAlarmKitStorage.removeLaunchAppOnDismiss(alarmId: alarm.id.uuidString)
                    stopped += 1
                } catch {
                    print("[ExpoAlarmKit] Failed to stop alerting alarm: \(error)")
                }
            }
            return stopped
        }

        // MARK: - Get All Alarms
        Function("getAllAlarms") { () -> [String] in
            return ExpoAlarmKitStorage.getAllAlarmIds()
        }

        
        // MARK: - Remove Alarm (from App Group storage only)
        Function("removeAlarm") { (id: String) in
            ExpoAlarmKitStorage.removeAlarm(id: id)
            ExpoAlarmKitStorage.removeLaunchAppOnDismiss(alarmId: id)
        }
        
        // MARK: - Clear All Alarms (from App Group storage only)
        Function("clearAllAlarms") { () in
            ExpoAlarmKitStorage.clearAllAlarms()
        }
        
        // MARK: - Get Launch Payload
        Function("getLaunchPayload") { () -> [String: Any]? in
            let payload = ExpoAlarmKitModule.launchPayload
            // Clear after retrieval
            ExpoAlarmKitModule.launchPayload = nil
            return payload
        }
    }
}
