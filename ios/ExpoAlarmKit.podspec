require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoAlarmKit'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author']
  s.homepage       = package['homepage']
  # 最低 OS を 16.4 に下げて iOS<26 と弱リンク共存させる（#145）。upstream は 26.1 固定で、
  # そのままだと iOS<26 をサポートするアプリに導入できない。AlarmKit を呼ぶ Swift は全て
  # @available(iOS 26.0, *) ガード済みのため、deployment target を下げても古い iOS では
  # モジュールが unavailable になるだけでビルドは通る。JS 側は iOS 26+ でのみ本モジュールを
  # require する（アプリ側 lib/alarm/iosAlarmKit.ts の遅延ロード）。
  s.platforms      = {
    :ios => '16.4',
  }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/nori-zooo/expo-alarm-kit' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INCLUDE_PATHS' => '$(inherited) $(PODS_CONFIGURATION_BUILD_DIR)/ExpoModulesCore',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_ROOT)/Headers/Public/ExpoModulesCore"',
  }

  # Only include the module implementation files
  # （View は削除済み。本 fork はアラームの予約・停止だけを担い UI コンポーネントを持たない）
  s.source_files = "ExpoAlarmKitModule.swift"
end
