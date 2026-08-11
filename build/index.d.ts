import { AuthorizationStatus, LaunchPayload } from './ExpoAlarmKitModule';
export { AuthorizationStatus, LaunchPayload };
/**
 * Configure the module with an App Group identifier.
 * This MUST be called before any other methods to enable shared storage
 * between your app and the alarm dismiss intent.
 *
 * @param appGroupIdentifier - The App Group identifier (e.g., "group.com.yourapp.alarms")
 * @returns True if configuration succeeded.
 *
 * @example
 * ```typescript
 * import { configure } from 'expo-alarm-kit';
 *
 * // Call this early in your app initialization
 * const success = configure('group.com.yourcompany.yourapp');
 * if (!success) {
 *   console.error('Failed to configure ExpoAlarmKit');
 * }
 * ```
 */
export declare function configure(appGroupIdentifier: string): boolean;
/**
 * Request authorization to schedule alarms.
 * On first call, this will prompt the user for permission.
 * @returns The current authorization status.
 */
export declare function requestAuthorization(): Promise<AuthorizationStatus>;
/**
 * Generate a valid UUID string for use as an alarm ID.
 * Call this before scheduling an alarm to get a unique identifier.
 * @returns A new UUID string.
 */
export declare function generateUUID(): string;
export interface ScheduleAlarmOptions {
    /** Unique identifier for the alarm */
    id: string;
    /** Unix timestamp in seconds for when the alarm should fire. Provide either this or date. */
    epochSeconds?: number;
    /** JavaScript Date object for when the alarm should fire. Provide either this or epochSeconds. */
    date?: Date;
    /** Title displayed for the alarm */
    title: string;
    /** Optional custom sound name (must exist in app bundle) */
    soundName?: string;
    /** Whether to launch the app when the alarm stop button is pressed. Defaults to false. */
    launchAppOnDismiss?: boolean;
    /** Optional payload string returned by getLaunchPayload when dismissed. Defaults to null. */
    dismissPayload?: string;
    /** Custom label for the stop button (default: 'Stop') */
    stopButtonLabel?: string;
    /** Hex color for the stop button text (default: '#FFFFFF') */
    stopButtonColor?: string;
    /** Hex color for the overall alarm tint (default: '#0000FF') */
    tintColor?: string;
}
/**
 * Schedule a one-time alarm.
 *
 * The alert presents a single "stop" button. This fork intentionally has no snooze:
 * no secondary button, and no `countdownDuration` (see ios/ExpoAlarmKitModule.swift).
 *
 * @param options - Alarm configuration options. Provide either epochSeconds or date.
 * @returns True if the alarm was scheduled successfully.
 */
export declare function scheduleAlarm(options: ScheduleAlarmOptions): Promise<boolean>;
/**
 * Cancel a scheduled alarm.
 * This removes the alarm from both AlarmKit and App Group storage.
 * @param id - The alarm ID to cancel.
 * @returns True if the alarm was cancelled successfully.
 */
export declare function cancelAlarm(id: string): Promise<boolean>;
/**
 * Stop alarms that are currently ringing (state == .alerting).
 *
 * AlarmKit owns the ringing; the only ways to stop it are the stop button's intent or
 * `AlarmManager.stop(id:)`. This reads the OS state directly, so it also recovers rings
 * whose IDs the app can no longer resolve (orphaned schedules) and rings whose alert UI
 * was destroyed without going through the stop button (e.g. device rotation).
 * Scheduled (not yet fired) alarms are left untouched.
 *
 * @returns The number of alarms stopped.
 */
export declare function stopAlertingAlarms(): Promise<number>;
/**
 * Get all currently scheduled alarm IDs.
 * @returns Array of alarm IDs.
 */
export declare function getAllAlarms(): string[];
export declare function clearAllAlarms(): void;
/**
 * Remove an alarm from App Group storage.
 * Note: This does NOT cancel the native alarm. Use cancelAlarm() to fully cancel an alarm.
 * @param id - The alarm ID to remove from storage.
 */
export declare function removeAlarm(id: string): void;
/**
 * Get the launch payload if the app was opened from an alarm dismiss intent.
 * The payload contains the alarmId and payload string (or null if not provided).
 * Note: The payload is cleared after retrieval, so subsequent calls will return null.
 * @returns The launch payload or null if not launched from an alarm.
 */
export declare function getLaunchPayload(): LaunchPayload | null;
declare const ExpoAlarmKit: {
    configure: typeof configure;
    requestAuthorization: typeof requestAuthorization;
    generateUUID: typeof generateUUID;
    scheduleAlarm: typeof scheduleAlarm;
    cancelAlarm: typeof cancelAlarm;
    stopAlertingAlarms: typeof stopAlertingAlarms;
    getAllAlarms: typeof getAllAlarms;
    clearAllAlarms: typeof clearAllAlarms;
    removeAlarm: typeof removeAlarm;
    getLaunchPayload: typeof getLaunchPayload;
};
export default ExpoAlarmKit;
//# sourceMappingURL=index.d.ts.map