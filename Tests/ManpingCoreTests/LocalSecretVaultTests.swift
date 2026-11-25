import Foundation
import XCTest

@testable import ManpingCore

final class LocalSecretVaultTests: XCTestCase {
  private var root: URL!
  private var directory: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-" + UUID().uuidString, isDirectory: true)
    directory = root.appendingPathComponent("Secrets", isDirectory: true)
  }
  override func tearDownWithError() throws {
    _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try? FileManager.default.removeItem(at: root)
  }

  private func vault(device: String = "DEVICE-A") -> LocalSecretVault {
    LocalSecretVault(directory: directory, deviceID: { device })
  }

  func testSealedOwnerOnlyFilesAndRoundTripAcrossInstances() throws {
    let secret = Data("SESSDATA=secret-value".utf8)
    try vault().write("bilibili.session", secret)
    XCTAssertEqual(try vault().read("bilibili.session"), secret, "a new launch reads it back")

    let file = directory.appendingPathComponent("bilibili.session.sealed")
    let stored = try Data(contentsOf: file)
    XCTAssertNil(stored.range(of: Data("secret-value".utf8)), "never stored in plain text")
    let mode = { (url: URL) in (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue }
    XCTAssertEqual(try mode(file), 0o600)
    XCTAssertEqual(try mode(directory.appendingPathComponent("vault.key")), 0o600)
    XCTAssertEqual(try mode(directory), 0o700)
    XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
    XCTAssertEqual(leftovers, [])

    try vault().delete("bilibili.session")
    XCTAssertNil(try vault().read("bilibili.session"))
    XCTAssertNoThrow(try vault().delete("bilibili.session"), "deleting an absent entry is fine")
  }

  func testAnotherMacOrARenamedFileReadsAsAbsent() throws {
    try vault().write("ai.provider.openai", Data("key-a".utf8))
    XCTAssertNil(try vault(device: "DEVICE-B").read("ai.provider.openai"), "bound to the hardware UUID")

    try vault().write("ai.provider.deepseek", Data("key-b".utf8))
    let from = directory.appendingPathComponent("ai.provider.deepseek.sealed")
    let to = directory.appendingPathComponent("ai.provider.openai.sealed")
    try FileManager.default.removeItem(at: to)
    try FileManager.default.moveItem(at: from, to: to)
    XCTAssertNil(try vault().read("ai.provider.openai"), "an entry cannot stand in for another")

    try vault().write("ai.provider.openai", Data("key-c".utf8))
    XCTAssertEqual(try vault().read("ai.provider.openai"), Data("key-c".utf8), "the next save replaces it")
  }

  func testMissingDeviceIdentifierFailsInsteadOfUsingAnotherKey() throws {
    try vault().write("bilibili.session", Data("a".utf8))
    let broken = LocalSecretVault(directory: directory, deviceID: { nil })
    XCTAssertThrowsError(try broken.read("bilibili.session")) { XCTAssertEqual($0 as? LocalSecretVault.Failure, .deviceUnavailable) }
    XCTAssertThrowsError(try broken.write("bilibili.session", Data("b".utf8)))
    XCTAssertEqual(try vault().read("bilibili.session"), Data("a".utf8), "nothing was overwritten")
  }

  func testNamesAreValidated() {
    for name in ["", ".hidden", "../escape", "a/b", "中文", String(repeating: "a", count: 97)] {
      XCTAssertThrowsError(try vault().write(name, Data())) { XCTAssertEqual($0 as? LocalSecretVault.Failure, .invalidName) }
    }
    XCTAssertNoThrow(try vault().write("ai.provider.azure_openai", Data()))
  }

  func testMemoryVaultNeverTouchesDisk() throws {
    let memory = LocalSecretVault(directory: nil)
    try memory.write("bilibili.session", Data("a".utf8))
    XCTAssertEqual(try memory.read("bilibili.session"), Data("a".utf8))
    try memory.delete("bilibili.session")
    XCTAssertNil(try memory.read("bilibili.session"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testStoresUseTheVault() async throws {
    let shared = vault()
    let ai = AILocalSecretStore(vault: shared)
    var secrets = AIProviderSecrets(key: "sk-test", secret: "s")
    secrets.configurationBinding = "binding"
    try ai.save(secrets, for: .openAI)
    let loaded = try XCTUnwrap(try AILocalSecretStore(vault: vault()).load(.openAI))
    XCTAssertEqual(loaded.key, "sk-test"); XCTAssertEqual(loaded.secret, "s"); XCTAssertEqual(loaded.configurationBinding, "binding")
    try ai.delete(.openAI)
    XCTAssertNil(try ai.load(.openAI))

    let plan = ChatGPTPlanLocalStore(vault: shared)
    try plan.saveHostID("urn:uuid:host")
    try plan.savePendingClientID("client-1")
    XCTAssertEqual(try ChatGPTPlanLocalStore(vault: vault()).loadHostID(), "urn:uuid:host")
    XCTAssertEqual(try plan.loadPendingClientID(), "client-1")
    try plan.savePendingClientID(nil)
    XCTAssertNil(try plan.loadPendingClientID())
  }

  func testThisMacHasAHardwareIdentifier() {
    XCTAssertFalse((LocalSecretVault.platformUUID() ?? "").isEmpty)
  }

  func testTestProcessesDoNotUseTheUsersFolder() throws {
    try LocalSecretVault.shared.write("test.probe", Data("x".utf8))
    let real = AppIdentity.applicationSupportDirectory
      .appendingPathComponent("Secrets/test.probe.sealed")
    XCTAssertFalse(FileManager.default.fileExists(atPath: real.path))
    try LocalSecretVault.shared.delete("test.probe")
  }

  func testInstancesSharingAFolderAgreeOnTheKey() throws {
    let instances = (0..<4).map { _ in vault() }
    DispatchQueue.concurrentPerform(iterations: 16) { index in
      try? instances[index % 4].write("entry\(index)", Data("value\(index)".utf8))
    }
    let fresh = vault()
    for index in 0..<16 { XCTAssertEqual(try fresh.read("entry\(index)"), Data("value\(index)".utf8)) }
  }

  func testUnreadableKeyIsNeverReplaced() throws {
    try vault().write("bilibili.session", Data("a".utf8))
    let keyURL = directory.appendingPathComponent("vault.key")
    let original = try Data(contentsOf: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keyURL.path)
    XCTAssertThrowsError(try vault().read("bilibili.session")) { XCTAssertEqual($0 as? LocalSecretVault.Failure, .keyUnreadable) }
    XCTAssertThrowsError(try vault().write("ai.provider.openai", Data("b".utf8)))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    XCTAssertEqual(try Data(contentsOf: keyURL), original)
    XCTAssertEqual(try vault().read("bilibili.session"), Data("a".utf8))
  }

  func testDebugAndToolsDoNotShareTheReleaseAIConfiguration() {
    XCTAssertNil(LocalSecretVault.appVariant, "test processes are not the app")
    XCTAssertEqual(AIConfigurationStore.defaultFileURL.lastPathComponent, "ChatClientConfiguration.json")
  }
}
