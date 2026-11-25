import Foundation

public protocol AISecretStore: Sendable {
  func load(_ provider: AIProvider) throws -> AIProviderSecrets?
  func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws
  func delete(_ provider: AIProvider) throws
}

/// AI credentials use separate per-provider entries in `LocalSecretVault`, never the Bilibili
/// account entry.
public final class AILocalSecretStore: AISecretStore, Sendable {
  private let vault: LocalSecretVault
  public init(vault: LocalSecretVault = .shared) { self.vault = vault }
  private func entry(_ provider: AIProvider) -> String {
    "ai.provider." + provider.rawValue
  }
  public func load(_ provider: AIProvider) throws -> AIProviderSecrets? {
    let name = entry(provider)
    guard let data = try vault.read(name) else { return nil }
    guard data.count <= 256 * 1024,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String], let key = object["key"] else {
      throw AIConfigurationError.corruptConfiguration
    }
    var secrets = AIProviderSecrets(key: key, secret: object["secret"], codestralKey: object["codestral_key"])
    secrets.configurationBinding = object["configuration_binding"]
    return secrets
  }
  public func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws {
    var object = ["key": secrets.key]
    object["secret"] = secrets.secret; object["codestral_key"] = secrets.codestralKey
    object["configuration_binding"] = secrets.configurationBinding
    let name = entry(provider)
    try vault.write(name, try JSONSerialization.data(withJSONObject: object))
  }
  public func delete(_ provider: AIProvider) throws {
    try vault.delete(entry(provider))
  }
}

/// In-memory fixture storage is intentionally independent of UserDefaults, the local vault and real configuration files.
public final class AIMemorySecretStore: AISecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [AIProvider: AIProviderSecrets]
  public init(values: [AIProvider: AIProviderSecrets] = [:]) { self.values = values }
  public func load(_ provider: AIProvider) throws -> AIProviderSecrets? {
    lock.lock(); defer { lock.unlock() }; return values[provider]
  }
  public func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws {
    lock.lock(); defer { lock.unlock() }; values[provider] = secrets
  }
  public func delete(_ provider: AIProvider) throws {
    lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: provider)
  }
}
