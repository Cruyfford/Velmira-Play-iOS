import SwiftUI
import Foundation

// MWIII 2023 includes the MWII (2022) carry-forward catalog.
// Reference: the separate MWIII (60) and MWII (77) weapon directories
// at bosslobbies.com/guides, cross-checked with sym.gg/gunsmith/mw3.
// Photographs are fetched only when a card becomes visible; if a remote
// photo is unavailable the UI shows an honest placeholder rather than
// labeling another weapon's image as the selected one.
struct MW3Weapon: Identifiable, Hashable {
    let id: String
    let name: String
    let category: Category
    let generation: String

    enum Category: String, CaseIterable, Identifiable {
        case assault = "بنادق هجومية"
        case battle = "بنادق قتالية"
        case smg = "رشاشات خفيفة"
        case shotgun = "شوزن"
        case lmg = "رشاشات ثقيلة"
        case marksman = "بنادق دقيقة"
        case sniper = "سنايبر"
        case handgun = "مسدسات"
        case launcher = "قاذفات"
        case melee = "اشتباك قريب"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .assault, .battle, .marksman: "scope"
            case .smg: "bolt.horizontal.circle"
            case .shotgun: "burst"
            case .lmg: "shield"
            case .sniper: "viewfinder"
            case .handgun: "target"
            case .launcher: "flame"
            case .melee: "hand.raised"
            }
        }
    }

    var imageURL: URL? {
        // The catalog website owns these distinct weapon renders.
        let base = generation == "MWIII" ? "mw3-2023" : "mw2-2022"
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return URL(string: "https://bosslobbies.com/wp-content/themes/boss-child/assets/weapons/\(base)/full/\(slug).webp")
    }

    static let all: [MW3Weapon] = {
        let groups: [(Category, String, String)] = [
            (.assault, "MWIII", "BAL-27|BP50|DG-56|FR 5.56|Holger 556|MCW|MTZ-556|RAM-7|STG44|SVA 545"),
            (.battle, "MWIII", "BAS-B|DTIR 30-06|MTZ-762|Sidewinder|SOA Subverter"),
            (.smg, "MWIII", "AMR9|FJX Horus|HRM-9|RAM-9|Rival-9|Static-HV|Striker|Striker 9|Superi 46|WSP-9|WSP Swarm"),
            (.shotgun, "MWIII", "Haymaker|Lockwood 680|Reclaimer 18|Riveter"),
            (.lmg, "MWIII", "Bruen Mk9|DG-58 LSW|Holger 26|Kastov LSW|Pulemyot 762|TAQ Eradicator|TAQ Evolvere"),
            (.marksman, "MWIII", "DM56|Kar98k|KVD Enforcer|MCW 6.8|MTZ Interceptor"),
            (.sniper, "MWIII", "KATT-AMR|KV Inhibitor|Longbow|MORS|XRK Stalker"),
            (.handgun, "MWIII", "COR-45|Renetti|TYR|WSP Stinger"),
            (.launcher, "MWIII", "RGL-80|Stormender|Torque 35"),
            (.melee, "MWIII", "Gladiator|Gutter Knife|Karambit|Sledgehammer|Soulrender|Spear"),
            (.assault, "MWII", "Chimera|FR Avancer|ISO Hemlock|Kastov 545|Kastov 762|Kastov-74U|Lachmann-556|M13B|M13C|M16|M4|STB 556|TAQ-56|Tempus Razorback|TR-76 Geist"),
            (.battle, "MWII", "Cronen Squall|FTAC Recon|Lachmann-762|SO-14|TAQ-V"),
            (.smg, "MWII", "BAS-P|Fennec 45|FSS Hurricane|ISO 45|ISO 9mm|Lachmann Shroud|Lachmann Sub|Minibak|MX9|PDSW 528|Vaznev-9K|VEL 46"),
            (.shotgun, "MWII", "Bryson 800|Bryson 890|Expedite 12|KV Broadside|Lockwood 300|MX Guardian"),
            (.lmg, "MWII", "556 Icarus|HCR 56|RAAL MG|RAPP H|RPK|SAKIN MG38"),
            (.marksman, "MWII", "Crossbow|EBR-14|LM-S|Lockwood MK2|SA-B 50|SP-R 208|TAQ-M|Tempus Torrent"),
            (.sniper, "MWII", "Carrack .300|FJX Imperium|LA-B 330|MCPR-300|Signal 50|SP-X 80|Victus XMR"),
            (.handgun, "MWII", ".50 GS|9mm Daemon|Basilisk|FTAC Siege|GS Magna|P890|X12|X13 Auto"),
            (.launcher, "MWII", "JOKR|PILA|RPG-7|STRELA-P"),
            (.melee, "MWII", "Combat Knife|Dual Kamas|Dual Kodachis|Pickaxe|Riot Shield|Tonfa")
        ]
        return groups.flatMap { category, generation, names in
            names.split(separator: "|").map { name in
                let n = String(name)
                return MW3Weapon(id: "\(generation):\(n)", name: n, category: category, generation: generation)
            }
        }
    }()
}

/// Suggested starting values, not measured recoil or verified ADS timings.
/// The user can customize every weapon independently.
struct MW3WeaponTuning: Codable, Equatable {
    var strength: Double
    var radius: Double
    var response: Double
    var recoil: Bool
    var recoilX: Double
    var recoilY: Double
    var quickScope: Bool
    var scopeDelay: Double
    var shotDuration: Double
    var silentShot: Bool
    var switchDelay: Double
    var switchDuration: Double

    static func suggested(for gun: MW3Weapon) -> MW3WeaponTuning {
        let c = gun.category
        let precision = c == .sniper || c == .marksman
        let automatic = c == .assault || c == .battle || c == .smg || c == .lmg
        var delay = 0.30
        if c == .sniper {
            switch gun.name {
            case "KATT-AMR": delay = 0.72
            case "XRK Stalker": delay = 0.60
            case "Longbow": delay = 0.50
            case "MORS": delay = 0.65
            default: delay = 0.60
            }
        } else if c == .marksman { delay = 0.40 }
        return MW3WeaponTuning(
            strength: precision ? 0.86 : (c == .smg ? 0.90 : 0.95),
            radius: precision ? 0.16 : (c == .smg ? 0.22 : 0.18),
            response: precision ? 0.12 : 0.11,
            recoil: false, // Never enable uncalibrated controller compensation.
            recoilX: 0,
            recoilY: automatic ? (c == .lmg ? 0.06 : 0.05) : 0,
            quickScope: false,
            scopeDelay: delay,
            shotDuration: 0.08,
            silentShot: false,
            switchDelay: 0.12,
            switchDuration: 0.07
        )
    }

    func apply(to config: inout AssistanceConfiguration) {
        config.strength = strength
        config.radius = radius
        config.response = response
        config.recoil = recoil
        config.recoilX = recoilX
        config.recoilY = recoilY
        config.quickScope = quickScope
        config.scopeDelay = scopeDelay
        config.shotDuration = shotDuration
        config.silentShot = silentShot
        config.switchDelay = switchDelay
        config.switchDuration = switchDuration
        // Preserve user-calibrated marker colors, body point, directions,
        // and safety-related controller behavior.
    }
}

private struct MW3WeaponArchive: Codable {
    var quickSlotIDs: [String?]
    var selectedID: String?
    var customTunings: [String: MW3WeaponTuning]
}

@MainActor
final class MW3WeaponStore: ObservableObject {
    static let shared = MW3WeaponStore()
    @Published private(set) var quickSlotIDs: [String?] = Array(repeating: nil, count: 6)
    @Published private(set) var selectedID: String?
    @Published private(set) var customTunings: [String: MW3WeaponTuning] = [:]
    @Published private(set) var lastMessage: String = ""
    private let key = "velmira.mw3.weaponProfiles.v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let archive = try? JSONDecoder().decode(MW3WeaponArchive.self, from: data) else { return }
        let known = Set(MW3Weapon.all.map(\.id))
        quickSlotIDs = Array(archive.quickSlotIDs.prefix(6)).map { id in
            guard let id, known.contains(id) else { return nil }
            return id
        }
        while quickSlotIDs.count < 6 { quickSlotIDs.append(nil) }
        selectedID = archive.selectedID.flatMap { known.contains($0) ? $0 : nil }
        customTunings = archive.customTunings.filter { known.contains($0.key) }
    }

    var selectedWeapon: MW3Weapon? { selectedID.flatMap(weapon(for:)) }
    func weapon(for id: String) -> MW3Weapon? { MW3Weapon.all.first { $0.id == id } }
    func weapon(in slot: Int) -> MW3Weapon? {
        guard (0..<6).contains(slot), let id = quickSlotIDs[slot] else { return nil }
        return weapon(for: id)
    }
    func tuning(for gun: MW3Weapon) -> MW3WeaponTuning {
        customTunings[gun.id] ?? .suggested(for: gun)
    }

    @discardableResult
    private func persist() -> Bool {
        let archive = MW3WeaponArchive(
            quickSlotIDs: quickSlotIDs, selectedID: selectedID, customTunings: customTunings)
        guard let data = try? JSONEncoder().encode(archive) else {
            lastMessage = "تعذر حفظ قائمة الأسلحة."
            return false
        }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    @discardableResult
    func saveTuning(_ tuning: MW3WeaponTuning, for gun: MW3Weapon) -> Bool {
        guard Self.valid(tuning) else {
            lastMessage = "إحدى القيم غير صالحة."
            return false
        }
        customTunings[gun.id] = tuning
        lastMessage = "تم حفظ إعدادات \(gun.name)."
        return persist()
    }

    @discardableResult
    func setSlot(_ slot: Int, gun: MW3Weapon) -> Bool {
        guard (0..<6).contains(slot) else { return false }
        // A weapon may occupy only one quick slot.
        for index in 0..<6 where quickSlotIDs[index] == gun.id {
            quickSlotIDs[index] = nil
        }
        quickSlotIDs[slot] = gun.id
        lastMessage = "تمت إضافة \(gun.name) إلى الخانة \(slot + 1)."
        return persist()
    }

    @discardableResult
    func addToFirstEmptySlot(_ gun: MW3Weapon) -> Bool {
        if quickSlotIDs.contains(gun.id) { return true }
        guard let index = quickSlotIDs.firstIndex(where: { $0 == nil }) else {
            lastMessage = "الخانات الست ممتلئة. اختر خانة لاستبدالها."
            return false
        }
        return setSlot(index, gun: gun)
    }

    func clearSlot(_ slot: Int) {
        guard (0..<6).contains(slot) else { return }
        quickSlotIDs[slot] = nil
        persist()
    }

    @discardableResult
    func apply(_ gun: MW3Weapon, tuning: MW3WeaponTuning? = nil) -> Bool {
        let preset = tuning ?? self.tuning(for: gun)
        guard Self.valid(preset) else { lastMessage = "الإعدادات غير صالحة."; return false }
        if let tuning { customTunings[gun.id] = tuning }
        // Disarm until the player explicitly enables assistance again.
        let assistance = AssistanceState.shared
        assistance.emergencyStop(reason: "تم اختيار سلاح \(gun.name) — أعد التفعيل يدويًا")
        var settings = assistance.configuration
        preset.apply(to: &settings)
        assistance.configuration = settings
        guard assistance.saveSettings() else {
            lastMessage = "تعذر حفظ إعدادات السلاح."
            return false
        }
        selectedID = gun.id
        let saved = persist()
        lastMessage = saved
            ? "تم تطبيق وحفظ إعدادات \(gun.name)."
            : "تم تطبيق السلاح لكن تعذر حفظ الاختيار."
        return saved
    }

    private static func valid(_ t: MW3WeaponTuning) -> Bool {
        func within(_ x: Double, _ low: Double, _ high: Double) -> Bool {
            x.isFinite && x >= low && x <= high
        }
        return within(t.strength, 0.1, 5) &&
            within(t.radius, 0.05, 0.5) &&
            within(t.response, 0.02, 0.5) &&
            within(t.recoilX, -0.3, 0.3) &&
            within(t.recoilY, -0.3, 0.3) &&
            within(t.scopeDelay, 0.05, 2) &&
            within(t.shotDuration, 0.03, 0.3) &&
            within(t.switchDelay, 0.03, 1) &&
            within(t.switchDuration, 0.03, 0.3)
    }
}

struct MW3WeaponPhoto: View {
    let weapon: MW3Weapon
    var body: some View {
        AsyncImage(url: weapon.imageURL, transaction: Transaction(animation: .easeInOut)) { phase in
            switch phase {
            case .success(let picture):
                picture.resizable().scaledToFit()
            case .failure:
                placeholder
            case .empty:
                ZStack { placeholder; ProgressView().tint(.cyan) }
            @unknown default: placeholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 104)
        .clipped()
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("صورة السلاح \(weapon.name)")
    }
    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: weapon.category.symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("الصورة غير متاحة")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MW3WeaponCatalogView: View {
    @ObservedObject private var store = MW3WeaponStore.shared
    @State private var search = ""
    @State private var category: MW3Weapon.Category?
    @State private var generation = "الكل"

    private var weapons: [MW3Weapon] {
        MW3Weapon.all.filter { gun in
            (category == nil || category == gun.category) &&
            (generation == "الكل" || gun.generation == generation) &&
            (search.isEmpty || gun.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VelmiraSection("أسلحة Call of Duty MW3 — PS5") {
                    Text("137 سلاحًا: 60 من MW3 و77 سلاحًا من MW2 المنقولة. اختر السلاح لتعديل إعداداته وإضافته إلى ست خانات سريعة تظهر أثناء البث.")
                        .font(.footnote)
                    Text("الإعدادات المقترحة قيم تجريبية تحتاج معايرة على سلاحك وإضافاته، وليست نتيجة قياس حقيقي. الصور تعتمد على اتصال الإنترنت ومصدر خارجي.")
                        .font(.footnote).foregroundStyle(.orange)
                    TextField("ابحث باسم السلاح", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Picker("الجيل", selection: $generation) {
                        Text("الكل").tag("الكل")
                        Text("MW3").tag("MWIII")
                        Text("MW2 المنقولة").tag("MWII")
                    }
                    .pickerStyle(.segmented)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button("الكل") { category = nil }
                                .buttonStyle(.borderedProminent)
                                .tint(category == nil ? .cyan : .gray)
                            ForEach(MW3Weapon.Category.allCases) { item in
                                Button(item.rawValue) { category = item }
                                    .buttonStyle(.borderedProminent)
                                    .tint(category == item ? .cyan : .gray)
                            }
                        }
                    }
                }
                VelmiraSection("اختصارات البث — 6 أسلحة") {
                    ForEach(0..<6, id: \.self) { index in
                        HStack {
                            Text("\(index + 1)").font(.headline.monospacedDigit())
                            Text(store.weapon(in: index)?.name ?? "خانة فارغة")
                            Spacer()
                            if store.weapon(in: index) != nil {
                                Button("حذف", role: .destructive) { store.clearSlot(index) }
                            }
                        }
                    }
                    Text("يمكنك تغيير أو استبدال الخانات من صفحة كل سلاح. اختيار السلاح في البث يطبّق الإعدادات ويحفظها مباشرة.")
                        .font(.footnote)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(weapons) { gun in
                        NavigationLink {
                            MW3WeaponDetailView(weapon: gun)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                MW3WeaponPhoto(weapon: gun)
                                Text(gun.name)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
                                HStack {
                                    Text(gun.category.rawValue)
                                    Spacer(minLength: 2)
                                    Text(gun.generation == "MWIII" ? "MW3" : "MW2")
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                                if store.selectedID == gun.id {
                                    Label("مُطبّق", systemImage: "checkmark.circle.fill")
                                        .font(.caption2).foregroundStyle(.green)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if weapons.isEmpty {
                    ContentUnavailableView("لا توجد نتائج", systemImage: "magnifyingglass")
                }
            }
            .padding(16)
        }
        .background(TPPlayTheme.canvas)
        .navigationTitle("أسلحة MW3")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

struct MW3WeaponDetailView: View {
    let weapon: MW3Weapon
    @ObservedObject private var store = MW3WeaponStore.shared
    @State private var tuning: MW3WeaponTuning
    @State private var message = ""

    init(weapon: MW3Weapon) {
        self.weapon = weapon
        _tuning = State(initialValue: MW3WeaponStore.shared.tuning(for: weapon))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VelmiraSection(weapon.name) {
                    MW3WeaponPhoto(weapon: weapon)
                    Text(weapon.category.rawValue + " · " + weapon.generation)
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("إعدادات مبدئية لحساسية 9 أفقي / 9 رأسي. عدّلها بناءً على سلاحك والإضافات التي تستخدمها.")
                        .font(.footnote)
                }
                VelmiraSection("تتبّع وتجربة السلاح") {
                    tuningSlider("قوة التصحيح", value: $tuning.strength, range: 0.1...5)
                    tuningSlider("نطاق التتبع", value: $tuning.radius, range: 0.05...0.5)
                    tuningSlider("زمن التنعيم", value: $tuning.response, range: 0.02...0.5)
                }
                VelmiraSection("تعويض الارتداد") {
                    Toggle("تعويض الارتداد — بعد المعايرة فقط", isOn: $tuning.recoil)
                    tuningSlider("تعويض أفقي", value: $tuning.recoilX, range: -0.3...0.3)
                    tuningSlider("تعويض رأسي", value: $tuning.recoilY, range: -0.3...0.3)
                }
                VelmiraSection("السنايبر والماكرو") {
                    Toggle("Quick Scope", isOn: $tuning.quickScope)
                    tuningSlider("التأخير قبل الطلقة", value: $tuning.scopeDelay, range: 0.05...2)
                    tuningSlider("مدة R2", value: $tuning.shotDuration, range: 0.03...0.3)
                    Toggle("Silent Shot — تبديل سلاح فقط", isOn: $tuning.silentShot)
                    tuningSlider("تأخير المثلث", value: $tuning.switchDelay, range: 0.03...1)
                    tuningSlider("مدة ضغط المثلث", value: $tuning.switchDuration, range: 0.03...0.3)
                }
                VelmiraSection("حفظ وتطبيق الإعدادات") {
                    Button {
                        if store.apply(weapon, tuning: tuning) {
                            _ = store.addToFirstEmptySlot(weapon)
                        }
                        message = store.lastMessage
                    } label: {
                        Label("تطبيق إعدادات السلاح وحفظها", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(AcidButtonStyle(active: true))
                    Button("حفظ تخصيص هذا السلاح دون تطبيق") {
                        _ = store.saveTuning(tuning, for: weapon)
                        message = store.lastMessage
                    }
                    Text("ضع السلاح في خانة من الخانات الست — يمكنك استبدال الخانة بسهولة:")
                        .font(.footnote)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]) {
                        ForEach(0..<6, id: \.self) { index in
                            Button {
                                _ = store.saveTuning(tuning, for: weapon)
                                if store.setSlot(index, gun: weapon) {
                                    _ = store.apply(weapon, tuning: tuning)
                                }
                                message = store.lastMessage
                            } label: {
                                VStack {
                                    Text("خانة \(index + 1)").font(.caption.bold())
                                    Text(store.weapon(in: index)?.name ?? "فارغة")
                                        .font(.caption2).lineLimit(1)
                                }.frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.cyan)
                    }
                    Text("اختيار إعدادات السلاح يغيّر ملف Velmira Play المحفوظ، ولا يبدّل السلاح داخل لعبة PS5. أعد تشغيل المساعدة يدويًا إذا احتجت إليها.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(16)
        }
        .background(TPPlayTheme.canvas)
        .navigationTitle(weapon.name)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func tuningSlider(_ title: String, value: Binding<Double>,
                              range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title): \(value.wrappedValue, specifier: "%.2f")")
                .font(.subheadline)
            Slider(value: value, in: range)
        }
    }
}
