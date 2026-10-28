import Foundation
import Security

private struct StoredRemoteDevice: Codable {
    let name: String
    let duid: String
    let isPS5: Bool
}

private struct StoredPSNCredentials: Codable {
    let npsso: String
    let accessToken: String
    let refreshToken: String
    let tokenExpiry: TimeInterval
    let accountID: String
    let onlineID: String
    let clientDUID: String
}

struct RemoteConsoleConnection: Sendable {
    let accessToken: String
    let accountID: Data
    let consoleDUID: Data
    let isPS5: Bool
}

@MainActor
final class RemoteCredentialStore: ObservableObject {
    static let shared = RemoteCredentialStore()
    @Published private(set) var isLinking = false
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var statusMessage: String?
    @Published private var credentials: StoredPSNCredentials?
    @Published private var remoteDevices: [StoredRemoteDevice] = []
    @Published private(set) var storageError: String?

    private let keychain = RemoteCredentialKeychain()
    private let duidKey = "velmira.remote.client.duid.v1"
    private let preferredConsoleKey = "velmira.remote.selected.consoles.v1"

    var isSignedIn: Bool { credentials != nil }
    var linkedDevices: [String] { remoteDevices.filter(\.isPS5).map(\.name) }
    var accountName: String? { credentials?.onlineID }

    init() {
        do {
            let payload = try keychain.load()
            credentials = payload?.credentials
            remoteDevices = payload?.remoteDevices ?? []
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Browser sign-in is handled directly by Sony, never by an in-app password form.
    /// A stable 48-character client DUID must be used for both authentication and holepunching.
    func authorizationURL() -> URL? {
        let duid: String
        if let existing = credentials?.clientDUID, existing.count == 48 {
            duid = existing
        } else if let saved = UserDefaults.standard.string(forKey: duidKey), saved.count == 48 {
            duid = saved
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                statusMessage = "تعذر إنشاء معرّف جهاز آمن."
                return nil
            }
            duid = "0000000700410080" + bytes.map { String(format: "%02x", $0) }.joined()
            UserDefaults.standard.set(duid, forKey: duidKey)
        }
        var components = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "service_entity", value: "urn:service-entity:psn"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: PSNRemoteAuth.clientID),
            URLQueryItem(name: "redirect_uri", value: PSNRemoteAuth.redirectURI),
            URLQueryItem(name: "scope", value: PSNRemoteAuth.scopes),
            URLQueryItem(name: "duid", value: duid),
            URLQueryItem(name: "request_locale", value: "en_US"),
            URLQueryItem(name: "ui", value: "pr"),
            URLQueryItem(name: "service_logo", value: "ps"),
            URLQueryItem(name: "layout_type", value: "popup"),
            URLQueryItem(name: "smcid", value: "remoteplay"),
            URLQueryItem(name: "prompt", value: "always"),
        ]
        return components.url
    }

    /// Exchange a one-use OAuth redirect locally. Never log, persist, or display the code.
    func linkFromPSNRedirect(_ value: String) async -> Bool {
        guard !isLinking else { return false }
        isLinking = true
        statusMessage = nil
        defer { isLinking = false }
        do {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: text),
                  components.host?.lowercased() == "remoteplay.dl.playstation.net",
                  components.path == "/remoteplay/redirect",
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else {
                throw RemoteSetupError.message("انسخ رابط Sony النهائي كاملًا؛ يجب أن يحتوي على code.")
            }
            guard let duid = UserDefaults.standard.string(forKey: duidKey),
                  duid.count == 48 else {
                throw RemoteSetupError.message("افتح صفحة تسجيل الدخول من داخل إعداد الاتصال البعيد أولًا.")
            }
            let result = try await tokenExchange(code: code, duid: duid)
            let account = try await accountIdentity(accessToken: result.access)
            guard let numericAccount = UInt64(account.id) else {
                throw RemoteSetupError.message("تعذر التحقق من معرّف حساب PlayStation.")
            }
            var littleEndian = numericAccount.littleEndian
            let encodedAccount = withUnsafeBytes(of: &littleEndian) { Data($0).base64EncodedString() }
            let devices = try await fetchRemoteDevices(token: result.access)
            let credential = StoredPSNCredentials(
                npsso: "", accessToken: result.access, refreshToken: result.refresh,
                tokenExpiry: Date().timeIntervalSince1970 * 1000 + result.expires * 1000,
                accountID: encodedAccount, onlineID: account.onlineID,
                clientDUID: duid
            )
            try keychain.save(RemoteCredentialPayload(credentials: credential, remoteDevices: devices))
            credentials = credential
            remoteDevices = devices
            statusMessage = devices.isEmpty
                ? "تم تسجيل الدخول، لكن لم يُعثر على PS5 مرتبط بالحساب. تأكد من Remote Play وحدث الأجهزة."
                : "تم ربط PSN للاتصال البعيد. الأجهزة المكتشفة: \(devices.count)."
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func updateRemoteDevices() async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }
        do {
            guard var current = credentials else {
                throw RemoteSetupError.message("يجب ربط حساب PlayStation للاتصال البعيد أولًا.")
            }
            if current.accessToken.isEmpty ||
               Date().timeIntervalSince1970 * 1000 >= current.tokenExpiry - 60_000 {
                current = try await refresh(current)
            }
            let found = try await fetchRemoteDevices(token: current.accessToken)
            try keychain.save(RemoteCredentialPayload(credentials: current, remoteDevices: found))
            credentials = current
            remoteDevices = found
            statusMessage = found.isEmpty ? "لم يُظهر PSN أي PS5 متاح. راجع حساب Sony وإعدادات Remote Play."
                : "تم تحديث أجهزة PSN: \(found.count)."
        } catch { statusMessage = error.localizedDescription }
    }

    func selectRemoteDevice(_ deviceName: String, for console: RegisteredConsole) {
        guard remoteDevices.contains(where: { $0.name == deviceName && $0.isPS5 }) else { return }
        var saved = UserDefaults.standard.dictionary(forKey: preferredConsoleKey) as? [String: String] ?? [:]
        saved[console.id] = deviceName
        UserDefaults.standard.set(saved, forKey: preferredConsoleKey)
        statusMessage = "حُدد جهاز \(deviceName) للاتصال البعيد."
    }

    func selectedDeviceName(for console: RegisteredConsole) -> String? {
        let saved = UserDefaults.standard.dictionary(forKey: preferredConsoleKey) as? [String: String] ?? [:]
        return saved[console.id]
    }

    func unlink() {
        do {
            try keychain.delete()
            credentials = nil
            remoteDevices = []
            statusMessage = "تم فصل تسجيل دخول الاتصال البعيد."
        } catch { statusMessage = error.localizedDescription }
    }

    private func tokenExchange(code: String, duid: String) async throws
        -> (access: String, refresh: String, expires: Double) {
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: PSNRemoteAuth.redirectURI),
            URLQueryItem(name: "client_id", value: PSNRemoteAuth.clientID),
            URLQueryItem(name: "client_secret", value: PSNRemoteAuth.clientSecret),
            URLQueryItem(name: "scope", value: PSNRemoteAuth.scopes),
            URLQueryItem(name: "duid", value: duid)
        ]
        var request = URLRequest(url: PSNRemoteAuth.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(PSNRemoteAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let json = try await fetchJSON(request)
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = json["refresh_token"] as? String, !refresh.isEmpty,
              let expiry = (json["expires_in"] as? NSNumber)?.doubleValue, expiry > 0 else {
            throw RemoteSetupError.message("لم يُرجع PSN بيانات اتصال صالحة. أعد تسجيل الدخول.")
        }
        return (access, refresh, expiry)
    }

    private func accountIdentity(accessToken: String) async throws -> (id: String, onlineID: String) {
        guard let encoded = accessToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token/" + encoded)
        else { throw RemoteSetupError.message("رمز PSN غير صالح.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let basic = Data("\(PSNRemoteAuth.clientID):\(PSNRemoteAuth.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic " + basic, forHTTPHeaderField: "Authorization")
        let json = try await fetchJSON(request)
        let id = (json["user_id"] as? String) ?? (json["user_id"] as? NSNumber)?.stringValue ?? ""
        let onlineID = json["online_id"] as? String ?? "PSN"
        guard UInt64(id) != nil else {
            throw RemoteSetupError.message("لم يتمكن PSN من إعادة رقم الحساب.")
        }
        return (id, onlineID)
    }

    private func fetchRemoteDevices(token: String) async throws -> [StoredRemoteDevice] {
        guard let url = URL(string: "https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/clients?platform=PS5&includeFields=device&limit=10&offset=0")
        else { throw RemoteSetupError.message("رابط PSN غير صالح.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        let json = try await fetchJSON(request)
        guard let list = json["clients"] as? [[String: Any]] else {
            throw RemoteSetupError.message("تعذر قراءة قائمة الأجهزة من PSN.")
        }
        var result: [StoredRemoteDevice] = []
        for record in list {
            guard let duid = record["duid"] as? String,
                  Data(hexString: duid)?.count == 32,
                  let device = record["device"] as? [String: Any],
                  let name = device["name"] as? String, !name.isEmpty,
                  let features = device["enabledFeatures"] as? [String],
                  features.contains("remotePlay") else { continue }
            result.append(StoredRemoteDevice(name: name, duid: duid, isPS5: true))
        }
        return result
    }

    private func fetchJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw RemoteSetupError.message("فشل الاتصال بخادم PlayStation.")
        }
        guard (200..<300).contains(status) else {
            throw RemoteSetupError.message("رفض PSN طلب الاتصال (HTTP \(status)).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteSetupError.message("استجابة PSN غير مفهومة.")
        }
        return json
    }

    func canAttemptRemoteConnection(for console: RegisteredConsole) -> Bool {
        guard let credentials,
              !credentials.accessToken.isEmpty || !credentials.refreshToken.isEmpty,
              let accountID = Data(base64Encoded: credentials.accountID), accountID.count == 8 else { return false }
        return remoteDevice(for: console) != nil
    }

    func connection(for console: RegisteredConsole) async throws -> RemoteConsoleConnection? {
        guard var credentials else { throw RemoteCredentialError.unavailable }
        guard let device = remoteDevice(for: console) else { return nil }

        if credentials.accessToken.isEmpty || Date().timeIntervalSince1970 * 1000 >= credentials.tokenExpiry {
            credentials = try await refresh(credentials)
            let payload = RemoteCredentialPayload(credentials: credentials, remoteDevices: remoteDevices)
            try keychain.save(payload)
            self.credentials = credentials
            storageError = nil
        }

        guard let accountID = Data(base64Encoded: credentials.accountID), accountID.count == 8 else {
            throw RemoteCredentialError.invalidAccount
        }
        guard let consoleDUID = Data(hexString: device.duid), consoleDUID.count == 32 else {
            throw RemoteCredentialError.invalidConsole
        }

        return RemoteConsoleConnection(
            accessToken: credentials.accessToken,
            accountID: accountID,
            consoleDUID: consoleDUID,
            isPS5: device.isPS5
        )
    }

    private func remoteDevice(for console: RegisteredConsole) -> StoredRemoteDevice? {
        let isPS5 = console.target >= 1_000_000
        let devices = remoteDevices.filter { $0.isPS5 == isPS5 }
        if let selected = selectedDeviceName(for: console),
           let preferred = devices.first(where: { $0.name == selected }) {
            return preferred
        }
        return devices.first {
            $0.name.caseInsensitiveCompare(console.nickname) == .orderedSame
        } ?? (devices.count == 1 ? devices[0] : nil)
    }

    private func refresh(_ credentials: StoredPSNCredentials) async throws -> StoredPSNCredentials {
        guard !credentials.refreshToken.isEmpty else { throw RemoteCredentialError.signInRequired }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: credentials.refreshToken),
            URLQueryItem(name: "scope", value: PSNRemoteAuth.scopes),
            URLQueryItem(name: "redirect_uri", value: PSNRemoteAuth.redirectURI),
            URLQueryItem(name: "client_id", value: PSNRemoteAuth.clientID),
            URLQueryItem(name: "client_secret", value: PSNRemoteAuth.clientSecret),
        ]

        var request = URLRequest(url: PSNRemoteAuth.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(PSNRemoteAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RemoteCredentialError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw RemoteCredentialError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if [400, 401, 403].contains(http.statusCode) {
                throw RemoteCredentialError.signInRequired
            }
            throw RemoteCredentialError.service(http.statusCode)
        }

        let refreshed: PSNTokenRefreshResponse
        do {
            refreshed = try JSONDecoder().decode(PSNTokenRefreshResponse.self, from: data)
        } catch {
            throw RemoteCredentialError.invalidResponse
        }
        guard !refreshed.accessToken.isEmpty, refreshed.expiresIn > 0 else {
            throw RemoteCredentialError.invalidResponse
        }

        let refreshToken = refreshed.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? credentials.refreshToken
        return StoredPSNCredentials(
            npsso: credentials.npsso,
            accessToken: refreshed.accessToken,
            refreshToken: refreshToken,
            tokenExpiry: Date().timeIntervalSince1970 * 1000 + refreshed.expiresIn * 1000,
            accountID: credentials.accountID,
            onlineID: credentials.onlineID,
            clientDUID: credentials.clientDUID
        )
    }
}

private enum RemoteSetupError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

private enum PSNRemoteAuth {
    static let tokenURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token")!
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let scopes = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
}

private struct PSNTokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct RemoteCredentialPayload: Codable {
    let credentials: StoredPSNCredentials
    let remoteDevices: [StoredRemoteDevice]
}

private struct RemoteCredentialKeychain {
    private let service = "com.mb14ck22.tpplay.remote-credentials"
    private let account = "pylux-import"

    func load() throws -> RemoteCredentialPayload? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RemoteCredentialError.keychain(status)
        }
        return try JSONDecoder().decode(RemoteCredentialPayload.self, from: data)
    }

    func delete() throws {
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteCredentialError.keychain(status)
        }
    }

    func save(_ payload: RemoteCredentialPayload) throws {
        let data = try JSONEncoder().encode(payload)
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteCredentialError.keychain(updateStatus)
        }
        var insert = key
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RemoteCredentialError.keychain(addStatus)
        }
    }
}

private enum RemoteCredentialError: LocalizedError {
    case keychain(OSStatus)
    case unavailable
    case invalidAccount
    case invalidConsole
    case network
    case service(Int)
    case invalidResponse
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        case .unavailable:
            return "No saved PSN credential is available."
        case .invalidAccount:
            return "The saved PSN account identifier is invalid."
        case .invalidConsole:
            return "The saved remote console identifier is invalid."
        case .network:
            return "Could not refresh the PSN credential. Check your network connection and try again."
        case .service(let status):
            return "PSN credential refresh failed (HTTP \(status)). Try again later."
        case .invalidResponse:
            return "PSN returned an invalid credential response. Try again later."
        case .signInRequired:
            return "The PSN session has expired and must be authorized again."
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
