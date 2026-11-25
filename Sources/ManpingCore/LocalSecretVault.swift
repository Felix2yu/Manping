import CryptoKit
import Foundation
import IOKit
import Security

public final class LocalSecretVault: @unchecked Sendable {
  public enum Failure: Error, LocalizedError, Equatable, Sendable {
    case invalidName, deviceUnavailable, unwritable, keyUnreadable
    public var errorDescription: String? {
      switch self {
      case .invalidName: "本地加密存储的项目名称无效。"
      case .deviceUnavailable: "无法读取本机硬件标识，本地加密存储暂不可用。"
      case .unwritable: "无法写入本地加密存储，请检查磁盘空间与「应用程序支持」目录权限。"
      case .keyUnreadable: "无法读取本地加密存储的密钥文件。请检查「应用程序支持/im.yufei.manping/Secrets\(LocalSecretVault.appVariant ?? "")」的权限；若文件已损坏，删除该目录后重新登录。"
      }
    }
  }

  private let directory: URL?
  private let deviceID: @Sendable () -> String?
  private let lock = NSLock()
  private var memory: [String: Data] = [:]
  private var key: SymmetricKey?

  public init(directory: URL?, deviceID: @escaping @Sendable () -> String? = LocalSecretVault.platformUUID) {
    self.directory = directory
    self.deviceID = deviceID
  }

  public static var appVariant: String? {
    AppIdentity.variant(for: Bundle.main.bundleIdentifier)
  }

  public static let shared: LocalSecretVault = {
    guard let variant = appVariant else { return LocalSecretVault(directory: nil) }
    let directory = AppIdentity.applicationSupportDirectory
      .appendingPathComponent("Secrets" + variant, isDirectory: true)
    return LocalSecretVault(directory: directory)
  }()

  public func read(_ name: String) throws -> Data? {
    try Self.validate(name)
    return try exclusive { try load(name) }
  }

  public func write(_ name: String, _ data: Data) throws {
    try Self.validate(name)
    try exclusive { try store(name, data) }
  }

  public func delete(_ name: String) throws {
    try Self.validate(name)
    try exclusive {
      if let directory {
        let url = directory.appendingPathComponent(name + ".sealed")
        if unlink(url.path) != 0, errno != ENOENT { throw Failure.unwritable }
      } else {
        memory.removeValue(forKey: name)
      }
    }
  }

  private func exclusive<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock {
      guard let directory else { return try body() }
      try prepare(directory)
      let descriptor = open(directory.appendingPathComponent("vault.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw Failure.unwritable }
      defer { close(descriptor) }
      guard flock(descriptor, LOCK_EX) == 0 else { throw Failure.unwritable }
      defer { flock(descriptor, LOCK_UN) }
      return try body()
    }
  }

  private func load(_ name: String) throws -> Data? {
    guard let directory else { return memory[name] }
    guard let sealed = try? Data(contentsOf: directory.appendingPathComponent(name + ".sealed")) else { return nil }
    let key = try sealingKey()
    guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
    return try? AES.GCM.open(box, using: key, authenticating: Data(name.utf8))
  }

  private func store(_ name: String, _ data: Data) throws {
    guard let directory else { memory[name] = data; return }
    let sealed = try AES.GCM.seal(data, using: try sealingKey(), authenticating: Data(name.utf8)).combined ?? Data()
    guard !sealed.isEmpty else { throw Failure.unwritable }
    try atomicWrite(sealed, to: directory.appendingPathComponent(name + ".sealed"))
  }

  private func sealingKey() throws -> SymmetricKey {
    if let key { return key }
    guard let directory else { throw Failure.unwritable }
    guard let device = deviceID(), !device.isEmpty else { throw Failure.deviceUnavailable }
    let url = directory.appendingPathComponent("vault.key")
    let raw: Data
    do {
      raw = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unwritable }
      try atomicWrite(Data(bytes), to: url)
      raw = Data(bytes)
    } catch {
      throw Failure.keyUnreadable
    }
    guard raw.count == 32 else { throw Failure.keyUnreadable }
    let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(device.utf8),
      info: Data((AppIdentity.bundleIdentifier + " secret vault v1").utf8), outputByteCount: 32)
    key = derived
    return derived
  }

  private func prepare(_ directory: URL) throws {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      var values = URLResourceValues(); values.isExcludedFromBackup = true
      var folder = directory; try folder.setResourceValues(values)
    } catch {
      throw Failure.unwritable
    }
  }

  private func atomicWrite(_ data: Data, to url: URL) throws {
    let folder = url.deletingLastPathComponent()
    if folder == directory { try prepare(folder) }
    let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw Failure.unwritable
    }
    if rename(temporary.path, url.path) != 0 {
      unlink(temporary.path)
      throw Failure.unwritable
    }
  }

  static func validate(_ name: String) throws {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !name.isEmpty, name.count <= 96, !name.hasPrefix("."), name.allSatisfy(allowed.contains) else { throw Failure.invalidName }
  }

  public static func platformUUID() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }
}
