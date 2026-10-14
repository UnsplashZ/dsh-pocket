import Foundation

#if canImport(Security)
import Security
#endif

/// 客户端身份的存放处。
///
/// **身份必须持久化**：iroh 的 `SecretKey` 就是设备身份，配对后电脑端按这把公钥做白名单。
/// 每次启动换一把新密钥 = 每次都要重新配对。
public protocol TetherSecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, _ value: Data) throws
    func delete(_ key: String) throws
}

public enum TetherSecretStoreError: Error, Sendable {
    case keychain(status: Int32)
    case fileSystem(String)
}

#if canImport(Security)
/// iOS / macOS 的 Keychain 实现。
///
/// 用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：设备解锁后可用（后台重连需要），
/// 且**不随 iCloud 钥匙串同步**（身份属于这台设备，同步到别的设备会变成"两台设备共用一把钥匙"）。
public struct KeychainSecretStore: TetherSecretStore {
    private let service: String

    public init(service: String = "cc.unsplashz.dshpocket.iroh") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw TetherSecretStoreError.keychain(status: status)
        }
    }

    public func write(_ key: String, _ value: Data) throws {
        let base = query(key)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TetherSecretStoreError.keychain(status: updateStatus)
        }
        var insert = base
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TetherSecretStoreError.keychain(status: addStatus)
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TetherSecretStoreError.keychain(status: status)
        }
    }
}
#endif

/// 落盘时用的写选项。
///
/// `.completeFileProtection*` 是 **iOS 的**数据保护类。在 macOS 上带上它写出来的文件
/// **读不回来**（`Data(contentsOf:)` 直接返回 nil，且写入本身不报错）—— 也就是说
/// 身份文件会静默丢失，表现成"每次启动都换一把新密钥、每次都要重新配对"。
/// `swift test` 与 M0b spike 都跑在 macOS 上，所以必须分平台。
enum TetherFileWrite {
    static var options: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUnlessOpen]
        #else
        return [.atomic]
        #endif
    }
}

/// 文件实现：`0600`、在 App 的 Application Support 下。
/// 用于单元测试与命令行 spike（无签名上下文时 Keychain 不可用）。
public struct FileSecretStore: TetherSecretStore {
    private let directory: URL

    public init(directory: URL = TetherStorage.directory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).secret")
    }

    public func read(_ key: String) throws -> Data? {
        try? Data(contentsOf: url(key))
    }

    public func write(_ key: String, _ value: Data) throws {
        let target = url(key)
        let temporary = target.appendingPathExtension("tmp")
        do {
            try value.write(to: temporary, options: TetherFileWrite.options)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            throw TetherSecretStoreError.fileSystem(error.localizedDescription)
        }
    }

    public func delete(_ key: String) throws {
        try? FileManager.default.removeItem(at: url(key))
    }
}

/// 进程内存储：单元测试用，退出即失。
public final class EphemeralSecretStore: TetherSecretStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func write(_ key: String, _ value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}
