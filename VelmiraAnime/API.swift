import Foundation
import SwiftUI

// MARK: - Errors

enum APIError: LocalizedError {
    case unauthorized
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "يلزم تسجيل الدخول"
        case .message(let text): return text
        }
    }
}

// MARK: - Helpers

func str(_ value: Any?) -> String {
    if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
    if let n = value as? NSNumber { return n.stringValue }
    return ""
}

func enc(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
}

let providerReferer = "https://www.khkhkhkh.com/"
let providerOrigin = "https://www.khkhkhkh.com"
let providerUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"

// MARK: - API

enum API {
    static let defaultBase = "https://velmira-anime-v2-api.cruyfford4488.workers.dev"

    static var base: String {
        let saved = UserDefaults.standard.string(forKey: "base") ?? ""
        let b = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = b.isEmpty ? defaultBase : b
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    static func request(_ path: String,
                        method: String = "GET",
                        body: [String: Any]? = nil,
                        token: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw APIError.message("رابط الخادم غير صالح") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 40
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.message("تعذر الاتصال بالخادم، تحقق من الإنترنت")
        }
        let data = result.0
        let response = result.1
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if code == 401 && token != nil { throw APIError.unauthorized }
        if !(200..<300).contains(code) || (obj["ok"] as? Bool) == false {
            throw APIError.message(describe(str(obj["error"]), code: code))
        }
        return obj
    }

    static func describe(_ error: String, code: Int) -> String {
        switch error {
        case "invalid_credentials": return "اسم المستخدم أو كلمة المرور غير صحيحة"
        case "account_banned": return "هذا الحساب محظور"
        case "rate_limited": return "محاولات كثيرة، انتظر قليلاً ثم أعد المحاولة"
        case "unauthorized": return "يلزم تسجيل الدخول"
        case "video_url_missing": return "لم يتوفر رابط فيديو لهذه الحلقة"
        case "anime_source_format_unrecognized": return "مصدر الأنمي أعاد بيانات غير متوقعة"
        case "server_error": return "خطأ في الخادم، حاول لاحقاً"
        case "": return "الخادم أعاد HTTP \(code)"
        default: return "خطأ: \(error)"
        }
    }
}

// MARK: - Models

struct Anime: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let year: String
    let status: String

    init?(_ d: [String: Any]) {
        let id = str(d["id"]).isEmpty ? str(d["animeID"]) : str(d["id"])
        let name = str(d["name"]).isEmpty ? str(d["title"]) : str(d["name"])
        guard !id.isEmpty, !name.isEmpty else { return nil }
        self.id = id
        self.name = name
        var img = ""
        for key in ["image", "image300", "image170", "poster", "imageUrl"] {
            let v = str(d[key])
            if !v.isEmpty { img = v; break }
        }
        if !img.isEmpty && !img.lowercased().hasPrefix("http") {
            img = providerOrigin + (img.hasPrefix("/") ? img : "/" + img)
        }
        self.image = img
        self.year = str(d["year"])
        self.status = str(d["status"])
    }
}

struct Episode: Identifiable, Hashable {
    let id: String
    let name: String
    let number: String
    let image: String

    init?(_ d: [String: Any], index: Int) {
        let id = str(d["id"]).isEmpty ? str(d["epid"]) : str(d["id"])
        guard !id.isEmpty else { return nil }
        self.id = id
        self.name = str(d["name"])
        let n = str(d["number"])
        self.number = n.isEmpty ? String(index + 1) : n
        let img = str(d["image300"]).isEmpty ? str(d["image170"]) : str(d["image300"])
        self.image = (img.isEmpty || img.lowercased().hasPrefix("http")) ? img
            : providerOrigin + (img.hasPrefix("/") ? img : "/" + img)
    }
}

// MARK: - Session

@MainActor
final class Session: ObservableObject {
    @Published var token: String? = UserDefaults.standard.string(forKey: "token")
    @Published var username: String = UserDefaults.standard.string(forKey: "username") ?? ""

    var isLoggedIn: Bool { !(token ?? "").isEmpty }

    func login(_ login: String, _ password: String) async throws {
        let obj = try await API.request("/v2/auth/login", method: "POST",
                                        body: ["login": login, "password": password])
        let t = str(obj["token"])
        guard !t.isEmpty else { throw APIError.message("لم يرجع الخادم رمز الدخول") }
        let user = obj["user"] as? [String: Any]
        token = t
        username = str(user?["username"]).isEmpty ? login : str(user?["username"])
        UserDefaults.standard.set(t, forKey: "token")
        UserDefaults.standard.set(username, forKey: "username")
    }

    func logout() {
        token = nil
        username = ""
        UserDefaults.standard.removeObject(forKey: "token")
        UserDefaults.standard.removeObject(forKey: "username")
    }
}
