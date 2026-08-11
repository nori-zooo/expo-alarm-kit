export type AuthorizationStatus = 'authorized' | 'denied' | 'notDetermined';
export interface LaunchPayload {
    alarmId: string;
    payload: string | null;
}
export interface ScheduleAlarmOptions {
    id: string;
    epochSeconds: number;
    title: string;
    soundName?: string | null;
    launchAppOnDismiss?: boolean;
    dismissPayload?: string | null;
    stopButtonLabel?: string | null;
    stopButtonColor?: string | null;
    tintColor?: string | null;
}
interface ExpoAlarmKitModuleType {
    /**
     * Configure the module with an App Group identifier.
     * This MUST be called before any other methods.
     * @param appGroupIdentifier - The App Group identifier (e.g., "group.com.yourapp.alarms")
     * @returns True if configuration succeeded.
     */
    configure(appGroupIdentifier: string): boolean;
    /**
     * Request authorization to schedule alarms.
     * @returns The current authorization status after the request.
     */
    requestAuthorization(): Promise<AuthorizationStatus>;
    /**
     * Generate a valid UUID string for use as an alarm ID.
     * @returns A new UUID string.
     */
    generateUUID(): string;
    /**
     * Schedule a one-time alarm.
     * @param options - Alarm configuration options.
     * @returns True if scheduling succeeded.
     */
    scheduleAlarm(options: ScheduleAlarmOptions): Promise<boolean>;
    /**
     * Cancel a scheduled alarm.
     * @param id - The alarm ID to cancel.
     * @returns True if cancellation succeeded.
     */
    cancelAlarm(id: string): Promise<boolean>;
    /**
     * Stop alarms that are currently ringing (state == .alerting).
     * Reads the OS state directly, so it can also stop rings whose IDs the app can no longer
     * resolve (orphaned schedules) or whose alert UI was destroyed without the stop button.
     * Scheduled (not yet fired) alarms are left untouched.
     * @returns The number of alarms stopped.
     */
    stopAlertingAlarms(): Promise<number>;
    /**
     * Get all currently scheduled alarm IDs.
     * @returns Array of alarm IDs stored in UserDefaults.
     */
    getAllAlarms(): string[];
    /**
     * Remove an alarm from UserDefaults (does not cancel the native alarm).
     * @param id - The alarm ID to remove.
     */
    removeAlarm(id: string): void;
    /**
     * Clear all alarms from UserDefaults (does not cancel the native alarms).
     * This resets the list of alarm IDs stored in UserDefaults.
     */
    clearAllAlarms(): void;
    /**
     * Get the launch payload if the app was opened from an alarm dismiss intent.
     * The payload is cleared after retrieval.
     * @returns The launch payload or null if not launched from an alarm.
     */
    getLaunchPayload(): LaunchPayload | null;
}
declare const _default: ExpoAlarmKitModuleType;
export default _default;
//# sourceMappingURL=ExpoAlarmKitModule.d.ts.map