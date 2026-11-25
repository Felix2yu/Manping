import Foundation
import XCTest
@testable import ManpingCore

final class M7SettingsTests: XCTestCase {
  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let defaults = scratchDefaults("Manping.SettingsFixture")
    try body(defaults)
  }
  private func backupJSON(version: Any = 1, values: [String: Any] = [:], extra: [String: Any] = [:]) throws -> Data {
    var object: [String: Any] = ["schemaVersion": version, "values": values]
    object.merge(extra, uniquingKeysWith: { _, new in new })
    return try JSONSerialization.data(withJSONObject: object)
  }
  private func assertBackupError(_ data: Data, _ expected: MacSettingsBackupError,
    file: StaticString = #filePath, line: UInt = #line) {
    do {
      _ = try MacSettingsBackup.decode(data: data)
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      guard let error = error as? MacSettingsBackupError else {
        XCTFail("Unexpected error: \(error)", file: file, line: line); return
      }
      XCTAssertEqual(error, expected, file: file, line: line)
    }
  }
  func testTVPlaybackDefaultsAreConservativeAndRoundTrip() throws {
    try withDefaults { defaults in
      let initial = MacSettings.load(from: defaults)
      XCTAssertFalse(initial.bool(.videoSmoothMotion))
      XCTAssertEqual(initial.text(.fullscreenSurround), "black")
      XCTAssertEqual(initial.text(.danmakuGlyphStyle), DanmakuGlyphStyle.automatic.rawValue)
      let capabilities: Set<MacSettingKey> = [.videoSmoothMotion, .fullscreenSurround, .danmakuGlyphStyle]
      var settings = initial
      for (key, value): (MacSettingKey, MacSettingValue) in [(.videoSmoothMotion, .bool(true)),
        (.fullscreenSurround, .text("ambient")), (.danmakuGlyphStyle, .text("outline"))] {
        XCTAssertTrue(settings.set(key, value, capabilities: capabilities))
        settings.save(key, to: defaults)
      }
      XCTAssertEqual(settings, MacSettings.load(from: defaults))
      XCTAssertFalse(settings.set(.fullscreenSurround, .text("invalid"), capabilities: capabilities))
    }
  }
  func testLegacyPreferencesLoadAndAutoQualityRemovesOldSelection() throws {
    try withDefaults { defaults in
      defaults.set("深色", forKey: "appTheme")
      defaults.set("hevc", forKey: "preferredCodec")
      defaults.set(80, forKey: "preferredVideoQuality")
      defaults.set(true, forKey: "playWithoutP2P")
      var settings = MacSettings.load(from: defaults)
      XCTAssertEqual(settings.text(.theme), "深色")
      XCTAssertEqual(settings.text(.codec), "hevc")
      XCTAssertEqual(settings.number(.quality), 80)
      XCTAssertTrue(settings.bool(.avoidP2P))
      XCTAssertTrue(settings.set(.quality, .number(0), capabilities: [.quality]))
      settings.save(.quality, to: defaults)
      XCTAssertNil(defaults.object(forKey: "preferredVideoQuality"))
      XCTAssertEqual(MacSettings.load(from: defaults).number(.quality), 0)
    }
  }
  func testFiniteRangesInvalidChoiceAndPlatformConstraints() {
    var settings = MacSettings()
    XCTAssertTrue(settings.set(.stepForward, .number(99999), capabilities: [.stepForward]))
    XCTAssertEqual(settings.number(.stepForward), 600)
    XCTAssertFalse(settings.set(.stepForward, .number(.infinity), capabilities: [.stepForward]))
    XCTAssertFalse(settings.set(.codec, .text("unrecognized"), capabilities: [.codec]))
    XCTAssertEqual(settings.text(.codec), "h264")
    XCTAssertTrue(settings.set(.notifications, .bool(true), capabilities: [.notifications]))
    XCTAssertFalse(settings.set(.globalSpeed, .bool(false), capabilities: []))
    XCTAssertTrue(settings.bool(.globalSpeed))
  }
  func testInvalidPersistedValuesFallBackWithoutMutatingOtherPreferences() throws {
    try withDefaults { defaults in
      defaults.set("unexpected", forKey: MacSettingKey.theme.rawValue)
      defaults.set("av1", forKey: MacSettingKey.codec.rawValue)
      defaults.set("not-a-number", forKey: MacSettingKey.stepForward.rawValue)
      defaults.set(true, forKey: MacSettingKey.volume.rawValue)
      defaults.set("fixture-private-value", forKey: "UnrelatedPreference")
      let settings = MacSettings.load(from: defaults)
      XCTAssertEqual(settings.text(.theme), "跟随系统")
      XCTAssertEqual(settings.text(.codec), "av1")
      XCTAssertEqual(settings.number(.stepForward), 30)
      XCTAssertEqual(settings.number(.volume), 80)
      settings.save(.theme, to: defaults)
      XCTAssertEqual(defaults.string(forKey: "UnrelatedPreference"), "fixture-private-value")
    }
  }
  func testPathsRejectRelativeDirectoriesAndControlCharacters() {
    var settings = MacSettings()
    XCTAssertFalse(settings.set(.downloadDirectory, .text("../Downloads"), capabilities: [.downloadDirectory]))
    XCTAssertFalse(settings.set(.bbdownPath, .text("BBDown\nsecond"), capabilities: [.bbdownPath]))
    XCTAssertTrue(settings.set(.downloadDirectory, .text("/tmp/Bili Fixture"), capabilities: [.downloadDirectory]))
    XCTAssertTrue(settings.set(.bbdownPath, .text("BBDown"), capabilities: [.bbdownPath]))
    XCTAssertEqual(settings.text(.downloadDirectory), "/tmp/Bili Fixture")
    XCTAssertEqual(Set(MacSettingsCatalog.descriptors.map(\.key)).count, MacSettingKey.allCases.count)
  }
  func testSettingsBackupRoundTripIncludesEffectiveValuesAndOnlyAllowlist() throws {
    try withDefaults { defaults in
      var settings = MacSettings.load(from: defaults)
      let capabilities = Set(MacSettingKey.allCases)
      let edits: [(MacSettingKey, MacSettingValue)] = [
        (.theme, .text("深色")), (.volume, .number(45)), (.stepForward, .number(75)),
        (.notifications, .bool(true)), (.downloadDirectory, .text("/tmp/Manping Backup")),
        (.historyServer, .text("https://private:password@history.internal:8899")),
      ]
      for (key, value) in edits {
        XCTAssertTrue(settings.set(key, value, capabilities: capabilities))
        settings.save(key, to: defaults)
      }
      let original = MacSettings.load(from: defaults)
      let backup = MacSettingsBackup(settings: original)
      let data = try backup.encodedData()
      let decoded = try MacSettingsBackup.decode(data: data)
      XCTAssertEqual(decoded.schemaVersion, 1)
      XCTAssertEqual(Set(decoded.values.keys), Set(MacSettingsBackup.backupKeys.map(\.rawValue)))
      for key in MacSettingsBackup.backupKeys {
        XCTAssertEqual(decoded.values[key.rawValue], original[key])
        XCTAssertEqual(backup.values[key.rawValue], original[key])
      }
      XCTAssertFalse(decoded.values.keys.contains(MacSettingKey.historyServer.rawValue))
      XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("history.internal"))
      XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private:password"))

      let restoredDefaults = scratchDefaults("Manping.SettingsBackupRestored")
      var restored = MacSettings()
      for entry in decoded.settingValues {
        XCTAssertTrue(restored.set(entry.key, entry.value, capabilities: capabilities))
        restored.save(entry.key, to: restoredDefaults)
      }
      let loaded = MacSettings.load(from: restoredDefaults)
      for key in MacSettingsBackup.backupKeys { XCTAssertEqual(loaded[key], original[key]) }
      XCTAssertEqual(loaded.text(.historyServer), "")
      XCTAssertNil(restoredDefaults.object(forKey: MacSettingKey.historyServer.rawValue))
    }
  }
  func testSettingValuesUseExplicitCodableTypes() throws {
    let values: [MacSettingValue] = [.bool(true), .number(12.5), .text("深色")]
    let data = try JSONEncoder().encode(values)
    XCTAssertEqual(try JSONDecoder().decode([MacSettingValue].self, from: data), values)
    XCTAssertThrowsError(try JSONDecoder().decode(MacSettingValue.self,
      from: Data(#"{"type":"bool","value":"true"}"#.utf8)))
    XCTAssertThrowsError(try JSONDecoder().decode(MacSettingValue.self,
      from: Data(#"{"type":"text","value":"深色","extra":1}"#.utf8)))
  }
  func testSettingsBackupRejectsOldAndFutureSchemaVersions() throws {
    assertBackupError(try backupJSON(version: 0), .unsupportedSchemaVersion(0))
    assertBackupError(try backupJSON(version: 2), .unsupportedSchemaVersion(2))
    XCTAssertThrowsError(try MacSettingsBackup.decode(data: Data(#"{"schemaVersion":"1","values":{}}"#.utf8)))
  }
  func testSettingsBackupExcludesSensitiveKeysAndRejectsTheirImport() throws {
    let backup = MacSettingsBackup(settings: MacSettings())
    XCTAssertFalse(MacSettingsBackup.backupKeys.contains(.historyServer))
    XCTAssertEqual(MacSettingsBackup.excludedKeys, [MacSettingKey.historyServer.rawValue])
    XCTAssertFalse(backup.values.keys.contains(MacSettingKey.historyServer.rawValue))
    for rawKey in [MacSettingKey.historyServer.rawValue, "historyServer", "Manping.historyToken", "accessToken",
      "cookie", "Manping.aiAPIKey", "aiKey", "Manping.proxyPassword"] {
      let data = try backupJSON(values: [rawKey: ["type": "text", "value": "private-fixture-value"]])
      assertBackupError(data, .unknownSettingKey(rawKey))
    }
  }
  func testSettingsBackupRejectsUnknownKeysAndMalformedEnvelopes() throws {
    let value = ["type": "text", "value": "深色"]
    assertBackupError(try backupJSON(values: ["unknown.setting": value]), .unknownSettingKey("unknown.setting"))
    XCTAssertThrowsError(try MacSettingsBackup.decode(data: try backupJSON(extra: ["unexpected": true])))
    XCTAssertThrowsError(try MacSettingsBackup.decode(data: Data(#"{"schemaVersion":1}"#.utf8)))
    XCTAssertThrowsError(try MacSettingsBackup.decode(data: Data(#"{"schemaVersion":1,"values":[]}"#.utf8)))
  }
  func testSettingsBackupRejectsIllegalTypesAndValuesWithoutClamping() throws {
    let invalidValues: [(String, [String: Any])] = [
      (MacSettingKey.volume.rawValue, ["type": "bool", "value": true]),
      (MacSettingKey.theme.rawValue, ["type": "text", "value": 42]),
      (MacSettingKey.notifications.rawValue, ["type": "text", "value": "true"]),
      (MacSettingKey.stepForward.rawValue, ["type": "number", "value": "30"]),
      (MacSettingKey.codec.rawValue, ["type": "text", "value": "not-a-codec"]),
      (MacSettingKey.stepForward.rawValue, ["type": "number", "value": 601]),
      (MacSettingKey.stepForward.rawValue, ["type": "number", "value": 0]),
      (MacSettingKey.downloadDirectory.rawValue, ["type": "text", "value": "relative/path"]),
      (MacSettingKey.customMpv.rawValue, ["type": "text", "value": "relative/mpv"]),
      (MacSettingKey.theme.rawValue, ["type": "text", "value": " 深色 "]),
      (MacSettingKey.theme.rawValue, ["type": "text", "value": "深色", "extra": 1]),
    ]
    for (key, value) in invalidValues {
      // A valid entry alongside the invalid one must still make the complete import fail.
      let validKey = key == MacSettingKey.notifications.rawValue ? MacSettingKey.danmakuEnabled : MacSettingKey.notifications
      let values = [validKey.rawValue: ["type": "bool", "value": true], key: value]
      XCTAssertThrowsError(try MacSettingsBackup.decode(data: backupJSON(values: values)), key)
    }
  }
  func testSettingsBackupEnforcesOneMiBInputLimit() throws {
    let oversized = Data(repeating: 0x20, count: MacSettingsBackup.maximumDataSize + 1)
    assertBackupError(oversized, .dataTooLarge(limit: MacSettingsBackup.maximumDataSize))
    let valid = try MacSettingsBackup(settings: MacSettings()).encodedData()
    let atLimit = valid + Data(repeating: 0x20, count: MacSettingsBackup.maximumDataSize - valid.count)
    XCTAssertEqual(atLimit.count, MacSettingsBackup.maximumDataSize)
    XCTAssertEqual(try MacSettingsBackup.decode(data: atLimit).schemaVersion, 1)
  }
  func testWindowsOnlyOptionsAreRetiredAndTheirSavedValuesAreLeftAlone() throws {
    for raw in MacSettingsCatalog.retiredKeys {
      XCTAssertNil(MacSettingKey(rawValue: raw))
      XCTAssertFalse(MacSettingsCatalog.descriptors.contains { $0.key.rawValue == raw })
    }
    try withDefaults { defaults in
      defaults.set(true, forKey: "Manping.nvdec")
      defaults.set(false, forKey: "Manping.topNavigation")
      var settings = MacSettings.load(from: defaults)
      XCTAssertTrue(settings.set(.notifications, .bool(true), capabilities: [.notifications]))
      settings.save(.notifications, to: defaults)
      XCTAssertEqual(defaults.object(forKey: "Manping.nvdec") as? Bool, true)
      XCTAssertEqual(defaults.object(forKey: "Manping.topNavigation") as? Bool, false)
    }
  }
  func testEveryGroupButAIHasTitledSectionsWithSentenceDetails() {
    for group in MacSettingGroup.allCases where group != .ai {
      let sections = MacSettingsCatalog.sections(of: group)
      XCTAssertFalse(sections.isEmpty, group.rawValue)
      XCTAssertTrue(sections.allSatisfy { !$0.title.isEmpty && !$0.descriptors.isEmpty }, group.rawValue)
    }
    XCTAssertTrue(MacSettingsCatalog.sections(of: .ai).isEmpty)
    for descriptor in MacSettingsCatalog.descriptors {
      XCTAssertFalse(descriptor.title.hasSuffix("。"), descriptor.title)
      if !descriptor.detail.isEmpty { XCTAssertTrue(descriptor.detail.hasSuffix("。"), descriptor.title) }
      XCTAssertFalse(descriptor.detail.contains("PGC"), descriptor.title)
    }
    XCTAssertEqual(MacSettingsCatalog.sections(of: .general).map(\.title), ["外观", "侧边栏项目", "搜索建议", "滚动加速"])
  }
  func testOpenModeReadsAndWritesTheTwoOriginalKeys() {
    var settings = MacSettings()
    XCTAssertEqual(MacOpenMode(settings), .mainWindow)
    for mode in MacOpenMode.allCases {
      for (key, value) in mode.values {
        XCTAssertTrue(settings.set(key, value, capabilities: MacSettingsCatalog.openModeKeys))
      }
      XCTAssertEqual(MacOpenMode(settings), mode)
    }
    XCTAssertTrue(settings.set(.integratedPlayer, .bool(false), capabilities: [.integratedPlayer]))
    XCTAssertTrue(settings.set(.displayMode, .text("compact"), capabilities: [.displayMode]))
    XCTAssertEqual(MacOpenMode(settings), .detached)
  }
  func testMacOptionsKeepTheirPathAndValueConstraints() {
    var settings = MacSettings()
    XCTAssertTrue(settings.set(.audioExclusive, .bool(true), capabilities: [.audioExclusive]))
    XCTAssertFalse(settings.set(.customMpv, .text("../mpv"), capabilities: [.customMpv]))
    XCTAssertFalse(settings.set(.customLibMpv, .text("relative.dylib"), capabilities: [.customLibMpv]))
    XCTAssertTrue(settings.set(.customMpv, .text("/tmp/fixture/mpv"), capabilities: [.customMpv]))
    XCTAssertTrue(settings.set(.customLibMpv, .text("/tmp/fixture/libmpv.dylib"), capabilities: [.customLibMpv]))
    XCTAssertTrue(settings.set(.mpvProfile, .text("fast"), capabilities: [.mpvProfile]))
    XCTAssertTrue(settings.set(.logLevel, .text("v"), capabilities: [.logLevel]))
  }
  func testMomentNotificationsMatchLatestThreeAndRetainTenIDs() {
    let moments = (1...5).map { M7MomentNotification(id: String($0), title: "Fixture", publisher: "Sample",
      page: "video", mediaID: "100") }
    let plan = M7MomentNotificationPolicy.plan(moments, previousIDs: ["2", "old1", "old2", "old3", "old4", "old5", "old6", "old7", "old8", "old9"])
    XCTAssertEqual(plan.notifications.map(\.id), ["1", "3"])
    XCTAssertEqual(plan.rememberedIDs, ["1", "2", "3", "old1", "old2", "old3", "old4", "old5", "old6", "old7"])
    let repeatPlan = M7MomentNotificationPolicy.plan(moments, previousIDs: plan.rememberedIDs)
    XCTAssertTrue(repeatPlan.notifications.isEmpty)
    XCTAssertEqual(M7MomentNotificationPolicy.plan([], previousIDs: ["old"]).rememberedIDs, ["old"])
  }
  func testMomentNotificationDeduplicatesWithinFirstThreeWithoutPullingOlderEntries() {
    let moment = M7MomentNotification(id: "1", title: "Fixture", publisher: "Sample", page: "video", mediaID: "100")
    let ignored = M7MomentNotification(id: "4", title: "Older", publisher: "Sample", page: "video", mediaID: "101")
    let plan = M7MomentNotificationPolicy.plan([moment, moment, moment, ignored], previousIDs: [])
    XCTAssertEqual(plan.notifications, [moment])
    XCTAssertEqual(plan.rememberedIDs, ["1"])
  }

}
