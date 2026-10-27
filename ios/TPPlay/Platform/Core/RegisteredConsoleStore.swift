import Foundation
import Security

struct RegisteredConsole: Codable, Identifiable, Equatable, Sendable {
    let target: Int32
    let nickname: String
    let address: String
    let serverMAC: Data
    let registrationKey: Data
    let keyType: UInt32
    let key: Data
    let consolePIN: UInt32

    var id: String {
        serverMAC.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class RegisteredConsoleStore: ObservableObject {
    @Published private(set) var consoles: [RegisteredConsole] = []
    @Published private(set) var storageError: String?

    private let keychain = RegisteredConsoleKeychain()

    init() {
        do {
            consoles = try keychain.load()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func save(_ console: RegisteredConsole) throws {
        var updated = consoles.filter { $0.serverMAC != console.serverMAC }
        updated.append(console)
        try keychain.save(updated)
        consoles = updated
        storageError = nil
    }

    func remove(_ console: RegisteredConsole) {
        let updated = consoles.filter { $0.id != console.id }
        do {
            try keychain.save(updated)
            consoles = updated
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    func updateAddressIfNeeded(_ console: RegisteredConsole) {
        guard consoles.first(where: { $0.id == console.id })?.address != console.address else { return }
        do {
            try save(console)
        } catch {
            storageError = error.localizedDescription
        }
    }

    func registration(for console: DiscoveredConsole) -> RegisteredConsole? {
        consoles.first { registered in
            registered.nickname == console.name || registered.address == console.address
        }
    }
}

private struct RegisteredConsoleKeychain {
    private let service = "com.mb14ck22.tpplay.registered-consoles"
    private let account = "default"

    func load() throws -> [RegisteredConsole] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode([RegisteredConsole].self, from: data)
    }

    func save(_ consoles: [RegisteredConsole]) throws {
        let data = try JSONEncoder().encode(consoles)
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }
        var insert = key
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

@MainActor
final class ConsoleRegistration: ObservableObject {
    enum State: Equatable {
        case idle
        case registering
        case succeeded
        case failed(String)
        case canceled
    }

    @Published private(set) var state: State = .idle
    nonisolated(unsafe) private var registration: OpaquePointer?
    private var address = ""

    func start(console: DiscoveredConsole, accountID: Data, pin: UInt32, store: RegisteredConsoleStore) {
        guard state != .registering else { return }
        address = console.address
        state = .registering
        var errorCode: Int32 = 0
        let target = console.isPS5 ? max(console.target, 1_000_100) : (console.target == 0 ? 1_000 : console.target)

        registration = console.address.withCString { host in
            accountID.withUnsafeBytes { accountBytes in
                tp_play_registration_create(
                    target,
                    host,
                    false,
                    nil,
                    accountBytes.bindMemory(to: UInt8.self).baseAddress,
                    accountID.count,
                    pin,
                    tpPlayRegistrationCallback,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &errorCode
                )
            }
        }

        if registration == nil {
            state = .failed("Registration could not start (core error \(errorCode)).")
        } else {
            activeStores[ObjectIdentifier(self)] = store
        }
    }

    func cancel() {
        tp_play_registration_stop(registration)
    }

    deinit {
        tp_play_registration_stop(registration)
        tp_play_registration_destroy(registration)
    }

    fileprivate func finish(event: TPPlayRegistrationEvent, payload: RegistrationPayload?) {
        defer {
            tp_play_registration_destroy(registration)
            registration = nil
            activeStores.removeValue(forKey: ObjectIdentifier(self))
        }
        switch event.rawValue {
        case 0:
            state = .canceled
        case 2:
            guard let payload, let store = activeStores[ObjectIdentifier(self)] else {
                state = .failed("The console returned incomplete registration data.")
                return
            }
            do {
                try store.save(
                    RegisteredConsole(
                        target: payload.target,
                        nickname: payload.nickname,
                        address: address,
                        serverMAC: payload.serverMAC,
                        registrationKey: payload.registrationKey,
                        keyType: payload.keyType,
                        key: payload.key,
                        consolePIN: payload.consolePIN
                    )
                )
                state = .succeeded
            } catch {
                state = .failed("Registered, but secure storage failed: \(error.localizedDescription)")
            }
        default:
            let reason = payload?.applicationReason ?? 0
            let status = payload?.httpStatus ?? 0
            let stage = payload?.failureStage ?? 0
            if reason != 0 {
                state = .failed("رفض PS5 عملية الاقتران (رمز الجهاز: " +
                                String(format: "0x%08X", reason) +
                                "). تأكد من استخدام حساب PSN نفسه والرمز الحالي الظاهر على الجهاز.")
            } else if status != 0 {
                state = .failed("رفض الجهاز طلب التسجيل (HTTP \(status)). افتح إعدادات Remote Play وأنشئ رمز ربط جديدًا.")
            } else {
                switch stage {
                case 1:
                    state = .failed("لم يتم العثور على PS5 لإكمال الاقتران. تأكد من اتصال الهاتف والجهاز بنفس الشبكة.")
                case 2:
                    state = .failed("تعذر الاتصال بمنفذ التسجيل على PS5. تأكد من الشبكة وفتح شاشة إقران الجهاز.")
                case 3:
                    state = .failed("فشل إرسال طلب التسجيل أو استقبال الرد. تحقق من رمز PIN والشبكة وحاول مجددًا.")
                case 4:
                    state = .failed("فشل رد PS5 على طلب التسجيل. أنشئ رمز PIN جديدًا وتأكد من مطابقة حساب PSN.")
                default:
                    state = .failed("تعذر إكمال الاقتران. راجع رمز PIN وحساب PSN واتصال الشبكة.")
                }
            }
        }
    }
}

private struct RegistrationPayload: Sendable {
    let target: Int32
    let nickname: String
    let serverMAC: Data
    let registrationKey: Data
    let keyType: UInt32
    let key: Data
    let consolePIN: UInt32
    let applicationReason: UInt32
    let failureStage: UInt32
    let httpStatus: UInt32
}

@MainActor private var activeStores: [ObjectIdentifier: RegisteredConsoleStore] = [:]

private let tpPlayRegistrationCallback: @convention(c) (
    TPPlayRegistrationEvent,
    UnsafePointer<TPPlayRegisteredHost>?,
    UnsafeMutableRawPointer?
) -> Void = { event, host, context in
    guard let context else { return }
    let payload = host.map { pointer in
        let value = pointer.pointee
        return RegistrationPayload(
            target: Int32(value.target),
            nickname: value.nickname.map(String.init(cString:)) ?? "PlayStation",
            serverMAC: data(value.server_mac, count: value.server_mac_size),
            registrationKey: data(value.registration_key, count: value.registration_key_size),
            keyType: value.key_type,
            key: data(value.key, count: value.key_size),
            consolePIN: value.console_pin,
            applicationReason: value.application_reason,
            failureStage: value.failure_stage,
            httpStatus: value.http_status
        )
    }
    let registration = Unmanaged<ConsoleRegistration>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        registration.finish(event: event, payload: payload)
    }
}

private func data(_ pointer: UnsafePointer<UInt8>?, count: Int) -> Data {
    guard let pointer, count > 0 else { return Data() }
    return Data(bytes: pointer, count: count)
}
