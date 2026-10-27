import SwiftUI
import Darwin
import Security

#if os(iOS)
@MainActor private enum DiagnosticCredential {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.mb14ck22.tpplay.link-diagnostic", kSecAttrAccount as String: "server"]
    static func save(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query.merging(attributes) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DiagnosticFailure(message: "تعذر حفظ مفتاح مصادقة الفحص") }
    }
    static func load() -> String {
        if let provisioned = ProcessInfo.processInfo.environment["TPPLAY_DIAGNOSTIC_TOKEN"], provisioned.count >= 32 {
            try? save(provisioned)
        }
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
#endif

struct LinkDiagnosticResult: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let direction: String
    let targetMbps: Int
    let sent: Int
    let received: Int
    let receivedMbps: Double
    let jitterMs: Double
    let rttP95Ms: Double?
    var windowReceived: Int? = nil
    var drainSeconds: Double? = nil
    var receiverDiagnostics: LinkReceiverDiagnostics? = nil
    var lateReceived: Int? { windowReceived.map { max(0, received - $0) } }
    var lossPercent: Double { sent > 0 ? Double(max(0, sent - received)) / Double(sent) * 100 : 0 }
}

struct LinkReceiverDiagnostics: Codable {
    let originalReceiveBufferBytes: Int
    let actualReceiveBufferBytes: Int
    let bufferResizeSucceeded: Bool
    let bufferResizeErrno: Int?
    let activeLoopGapMaxMs: Double
    let activeLoopGapP95Ms: Double
    let activeLoopGapsOver20Ms: Int
    let largestReceiveBatch: Int
    let fullReceiveBatches: Int
    let receiveErrors: Int
    let lastReceiveErrno: Int?
    let sendErrors: Int
    // iOS public socket headers offer no per-socket overflow counter.
    // Missing telemetry is not a measured zero.
    var socketOverflowPackets: Int? = nil
}

private struct DiagnosticFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Socket work never runs on the UI thread. Cancellation is checked every 2ms
// during load; control operations are bounded by socket timeouts.
enum LinkProbe {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func run(host: String, token: String, rate: Int, direction: String) throws -> LinkDiagnosticResult {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(39876).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw DiagnosticFailure(message: "أدخل عنوان IPv4 لخادم الفحص")
        }
        func connectedSocket(_ type: Int32) throws -> Int32 {
            let fd = socket(AF_INET, type, 0)
            guard fd >= 0 else { throw DiagnosticFailure(message: "تعذر إنشاء اتصال الاختبار") }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if status != 0 {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                var error: Int32 = 0
                var length: socklen_t = 4
                guard errno == EINPROGRESS, poll(&p, 1, 3000) > 0,
                      getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                    close(fd)
                    throw DiagnosticFailure(message: "تعذر الوصول إلى خادم الفحص. تحقق من اتصال VPN وعنوان الخادم.")
                }
            }
            _ = fcntl(fd, F_SETFL, 0)
            return fd
        }
        let tcp = try connectedSocket(SOCK_STREAM)
        defer { close(tcp) }
        let udp = try connectedSocket(SOCK_DGRAM)
        defer { close(udp) }
        func receiveBufferSize() throws -> Int {
            var value: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: value))
            guard getsockopt(udp, SOL_SOCKET, SO_RCVBUF, &value, &size) == 0 else {
                throw DiagnosticFailure(message: "تعذر قراءة حجم مخزن استقبال UDP")
            }
            return Int(value)
        }
        let originalBuffer = try receiveBufferSize()
        var resizeSucceeded = false
        var resizeErrno: Int?
        // Diagnostic socket only. Never reduce an existing larger buffer.
        for candidate in [1_048_576, 524_288, 262_144] where candidate > originalBuffer {
            var requested = Int32(candidate)
            if setsockopt(udp, SOL_SOCKET, SO_RCVBUF, &requested, 4) == 0 {
                resizeSucceeded = true
                resizeErrno = nil
                break
            }
            resizeErrno = Int(errno)
        }
        let actualBuffer = try receiveBufferSize()
        func writeJSON(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = send(tcp, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    guard n > 0 else { throw DiagnosticFailure(message: "فشل الإرسال عبر اتصال التحكم بالفحص") }
                    offset += n
                }
            }
        }
        func readJSON() throws -> [String: Any] {
            var bytes = [UInt8]()
            while bytes.count < 4096 {
                try Task.checkCancellation()
                var byte: UInt8 = 0
                guard recv(tcp, &byte, 1, 0) == 1 else { throw DiagnosticFailure(message: "انتهت مهلة استجابة خادم الفحص أو انقطع الاتصال") }
                if byte == 10 { break }
                bytes.append(byte)
            }
            guard let value = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any], value["error"] == nil else {
                throw DiagnosticFailure(message: "رفض الخادم الاختبار. تحقق من مفتاح المصادقة أو انتظر انتهاء الاختبارات الأخرى.")
            }
            return value
        }
        try writeJSON(["token": token, "rate": rate, "direction": direction])
        let response = try readJSON()
        guard response["version"] as? Int == 2, response["drainSeconds"] as? Int == 10 else {
            throw DiagnosticFailure(message: "حدّث خدمة فحص الشبكة أولاً؛ الإصدار القديم لا يدعم إحصاء الحزم المتأخرة.")
        }
        guard let hex = response["cookie"] as? String, hex.count == 32 else { throw DiagnosticFailure(message: "بروتوكول الفحص غير متوافق") }
        var cookie = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw DiagnosticFailure(message: "بيانات اعتماد الاختبار غير صالحة") }
            cookie.append(byte)
            index = next
        }
        func packet(_ kind: UInt8, _ sequence: UInt32, _ stamp: Double, size: Int) -> [UInt8] {
            var p = cookie + [kind, 0, 0, 0]
            p += (0..<4).reversed().map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) }
            let bits = stamp.bitPattern
            p += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
            p += [UInt8](repeating: 0, count: size - 32)
            return p
        }
        _ = fcntl(udp, F_SETFL, O_NONBLOCK)
        let start = now()
        var previous = start
        var credit = 0.0
        var lastProbe = -Double.infinity
        var sent = 0
        var seen = Set<UInt32>()
        var bytes = 0
        var windowReceived = 0
        var jitter = 0.0
        var lastArrival: (UInt32, Double, Double)?
        var rtts = [Double]()
        var buffer = [UInt8](repeating: 0, count: 1500)
        var loopGaps = [Double]()
        var largestBatch = 0
        var fullBatches = 0
        var receiveErrors = 0
        var lastReceiveErrno: Int?
        var sendErrors = 0
        let packetsPerSecond = Double(rate) * 1e6 / 9600
        // Eight seconds of offered load, then ten seconds receiving only.
        // Missing after this deadline is not proof of permanent network loss.
        while now() - start < 18 {
            try Task.checkCancellation()
            let current = now()
            if current - start < 8 { loopGaps.append((current - previous) * 1000) }
            if current - lastProbe >= 0.1 {
                let p = packet(80, 0, current, size: 32)
                _ = p.withUnsafeBytes { send(udp, $0.baseAddress, $0.count, 0) }
                lastProbe = current
            }
            if direction == "upload", current - start < 8 {
                credit = min(credit + (current - previous) * packetsPerSecond, packetsPerSecond * 0.020)
                while credit >= 1 {
                    let p = packet(68, UInt32(sent), now(), size: 1200)
                    let n = p.withUnsafeBytes { send(udp, $0.baseAddress, $0.count, 0) }
                    if n == 1200 { sent += 1 } else { sendErrors += 1 }
                    credit -= 1
                }
            }
            previous = current
            // Bound receive work so a busy socket cannot starve cancellation.
            var batch = 0
            for _ in 0..<256 {
                let n = recv(udp, &buffer, buffer.count, 0)
                if n < 0 {
                    if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        receiveErrors += 1
                        lastReceiveErrno = Int(errno)
                    }
                    break
                }
                batch += 1
                if n < 32 { continue }
                guard Array(buffer[0..<16]) == cookie else { continue }
                let sequence = buffer[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let stamp = Double(bitPattern: buffer[24..<32].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
                let arrival = now()
                if buffer[16] == 80, stamp - start < 8 { rtts.append((arrival - stamp) * 1000) }
                if buffer[16] == 68, seen.insert(sequence).inserted {
                    if arrival - start < 8 {
                        bytes += n
                        windowReceived += 1
                    }
                    if let last = lastArrival, sequence > last.0 {
                        jitter += (abs((arrival - last.2) - (stamp - last.1)) - jitter) / 16
                    }
                    lastArrival = (sequence, stamp, arrival)
                }
            }
            largestBatch = max(largestBatch, batch)
            if batch == 256 { fullBatches += 1 }
            var p = pollfd(fd: udp, events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, 2)
        }
        try writeJSON([:])
        let final = try readJSON()
        let received: Int
        if direction == "upload" {
            received = (final["received"] as? Int) ?? 0
            bytes = (final["windowBytes"] as? Int) ?? 0
            windowReceived = (final["windowReceived"] as? Int) ?? 0
            jitter = ((final["jitterMs"] as? Double) ?? 0) / 1000
        } else {
            sent = (final["sent"] as? Int) ?? 0
            received = seen.count
        }
        guard sent > 0, !rtts.isEmpty else { throw DiagnosticFailure(message: "لم ينجح اتصال UDP؛ نجاح اتصال TCP لا يعني أن مسار البث يعمل.") }
        rtts.sort()
        loopGaps.sort()
        let diagnostics = LinkReceiverDiagnostics(
            originalReceiveBufferBytes: originalBuffer, actualReceiveBufferBytes: actualBuffer,
            bufferResizeSucceeded: resizeSucceeded, bufferResizeErrno: resizeErrno,
            activeLoopGapMaxMs: loopGaps.last ?? 0,
            activeLoopGapP95Ms: loopGaps.isEmpty ? 0 : loopGaps[Int(Double(loopGaps.count - 1) * 0.95)],
            activeLoopGapsOver20Ms: loopGaps.filter { $0 > 20 }.count,
            largestReceiveBatch: largestBatch, fullReceiveBatches: fullBatches,
            receiveErrors: receiveErrors, lastReceiveErrno: lastReceiveErrno, sendErrors: sendErrors)
        return LinkDiagnosticResult(direction: direction, targetMbps: rate, sent: sent, received: received,
                                    receivedMbps: Double(bytes) * 8 / 8 / 1e6, jitterMs: jitter * 1000,
                                    rttP95Ms: rtts[min(rtts.count - 1, Int(Double(rtts.count - 1) * 0.95))],
                                    windowReceived: windowReceived, drainSeconds: 10,
                                    receiverDiagnostics: diagnostics)
    }
}

#if os(iOS)
@MainActor final class LinkDiagnosticModel: ObservableObject {
    static var isTesting = false
    @Published var results: [LinkDiagnosticResult] = []
    @Published var status = "جاهز"
    @Published var running = false
    private var task: Task<Void, Never>?
    private let storage = "linkDiagnosticResults.v1"
    init() {
        if let data = UserDefaults.standard.data(forKey: storage), let saved = try? JSONDecoder().decode([LinkDiagnosticResult].self, from: data) { results = saved }
    }
    func cancel() { task?.cancel() }
    func start(host: String, token: String) {
        guard !running else { return }
        guard RemotePlaySession.diagnosticSession == nil else {
            status = "أغلق البث أولاً وانتظر انتهاء الاتصال، ثم ابدأ الاختبار."
            return
        }
        do { try DiagnosticCredential.save(token) }
        catch { status = error.localizedDescription; return }
        running = true
        Self.isTesting = true
        results = []
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer {
                running = false
                Self.isTesting = false
                UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled
            }
            do {
                for direction in ["download", "upload"] {
                    for rate in [3, 5, 7, 10, 15, 20] {
                        try Task.checkCancellation()
                        status = "\(direction == "download" ? "التنزيل" : "الرفع") • \(rate) ميغابت/ثانية"
                        let worker = Task.detached(priority: .userInitiated) {
                            try LinkProbe.run(host: host, token: token, rate: rate, direction: direction)
                        }
                        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                        results.append(result)
                        UserDefaults.standard.set(try JSONEncoder().encode(results), forKey: storage)
                    }
                }
                status = "اكتمل الاختبار"
            } catch is CancellationError { status = "تم الإلغاء — نتائج جزئية" }
            catch { status = error.localizedDescription }
        }
    }
    var export: String { (try? String(data: JSONEncoder().encode(results), encoding: .utf8)) ?? "[]" }
}

struct LinkDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = LinkDiagnosticModel()
    @AppStorage("linkDiagnosticHost") private var host = ""
    @State private var token = DiagnosticCredential.load()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("رجوع") { model.cancel(); dismiss() }.buttonStyle(AcidButtonStyle())
                Spacer()
                Text("فحص الاتصال").foregroundStyle(TPPlayTheme.accent)
            }.padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("اختبار UDP بين الهاتف وخادم الشبكة")
                    Text("لا يتصل هذا الاختبار بجهاز PS5 ولا يغيّر جودة البث. يفحص التنزيل والرفع بسرعات 3 و5 و7 و10 و15 و20 ميغابت/ثانية. يستمر الإرسال 8 ثوانٍ لكل سرعة، ثم ينتظر الحزم المتأخرة 10 ثوانٍ. يستغرق نحو 4 دقائق ويستهلك قرابة 120 ميغابايت إضافة إلى بيانات البروتوكول.")
                        .foregroundStyle(TPPlayTheme.secondaryText)
                    Text("هذا فحص متقدم يحتاج خادم فحص متوافقاً ومفتاح مصادقة. لربط جهازك واللعب، ارجع إلى قسم PS5.").font(.footnote).foregroundStyle(TPPlayTheme.secondaryText)
                    Text("عنوان خادم الفحص عبر الشبكة أو VPN").foregroundStyle(TPPlayTheme.accent)
                    TextField("عنوان IPv4 للخادم", text: $host).keyboardType(.decimalPad)
                        .environment(\.layoutDirection, .leftToRight)
                        .padding(12).frame(minHeight: 44).background(TPPlayTheme.surface).clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).stroke(TPPlayTheme.border, lineWidth: 1) }
                        .disabled(model.running)
                    Text("مفتاح المصادقة").foregroundStyle(TPPlayTheme.accent)
                    SecureField("مفتاح مصادقة خادم الفحص", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                        .padding(12).frame(minHeight: 44).background(TPPlayTheme.surface).clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).stroke(TPPlayTheme.border, lineWidth: 1) }
                        .disabled(model.running)
                    Button(model.running ? "إيقاف الاختبار" : "بدء الاختبار") {
                        if model.running { model.cancel() } else { model.start(host: host, token: token) }
                    }.frame(maxWidth: .infinity, minHeight: 48).buttonStyle(AcidButtonStyle(active: !model.running))
                    .disabled(!model.running && token.isEmpty)
                    Text(model.status).foregroundStyle(model.running ? TPPlayTheme.accent : TPPlayTheme.secondaryText)
                    Text("RTT هو زمن ذهاب حزمة الفحص وعودتها أثناء الحمل، وليس التأخير بين ضغط الزر وظهور الحركة. قد يكون انخفاض سرعة الاستقبال ناتجاً عن أداء المُرسل، وليس الشبكة وحدها.")
                        .foregroundStyle(TPPlayTheme.tertiaryText)
                    ForEach(model.results) { result in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(result.direction == "download" ? "التنزيل" : "الرفع") • \(result.targetMbps) ميغابت/ثانية").foregroundStyle(TPPlayTheme.accent)
                            if let window = result.windowReceived, let late = result.lateReceived {
                                Text(String(format: "سرعة الاستقبال خلال 8 ثوانٍ: %.2f ميغابت/ثانية", result.receivedMbps))
                                Text("المستلم أثناء الاختبار: \(window) / المتأخر: \(late)")
                                Text(String(format: "الحزم غير المستلمة بعد انتظار 10 ثوانٍ: %.2f%%", result.lossPercent))
                            } else {
                                Text("نتائج قديمة لا تميّز الحزم المتأخرة؛ أعد الاختبار.")
                                    .foregroundStyle(TPPlayTheme.danger)
                            }
                            Text(String(format: "زمن الرحلة P95: %.1f مللي ثانية / التذبذب: %.1f مللي ثانية", result.rttP95Ms ?? 0, result.jitterMs))
                            Text("المُرسل: \(result.sent) / المستلم: \(result.received)")
                            if let d = result.receiverDiagnostics {
                                Text("مخزن UDP على الهاتف: \(d.originalReceiveBufferBytes) → \(d.actualReceiveBufferBytes) B")
                                Text(String(format: "الفاصل بين دورات الاستقبال: P95 %.1f / الأقصى %.1f مللي ثانية", d.activeLoopGapP95Ms, d.activeLoopGapMaxMs))
                                Text("أكبر دفعة: \(d.largestReceiveBatch) حزمة / أخطاء الاستقبال: \(d.receiveErrors)")
                                Text("تعذر قراءة عدد مرات امتلاء المخزن؛ غياب أخطاء الاستقبال لا يعني عدم فقد حزم.")
                                    .foregroundStyle(TPPlayTheme.tertiaryText)
                            }
                            if Double(result.sent) * 1200 / 1e6 < Double(result.targetMbps) * 0.95 {
                                Text("لم يصل المُرسل إلى السرعة المطلوبة؛ لا يمكن استخدام هذه النتيجة لتحديد سعة الاتصال.")
                                    .foregroundStyle(TPPlayTheme.danger)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(TPPlayTheme.surface).clipShape(RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(TPPlayTheme.border, lineWidth: 1) }
                    }
                    if !model.results.isEmpty { ShareLink("مشاركة النتائج", item: model.export).buttonStyle(AcidButtonStyle()) }
                }.padding(20)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .environment(\.layoutDirection, .rightToLeft)
        .foregroundStyle(TPPlayTheme.primaryText).background(TPPlayTheme.canvas)
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.cancel() } }
    }
}
#endif
