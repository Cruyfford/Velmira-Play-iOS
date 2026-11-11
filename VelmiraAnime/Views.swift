import SwiftUI
import UIKit

// MARK: - Theme (streaming-style: black, red accent)

enum Theme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let card = Color(red: 0.14, green: 0.14, blue: 0.14)
    static let accent = Color(red: 0.90, green: 0.04, blue: 0.08)
    static let muted = Color(white: 0.64)
    static let match = Color(red: 0.27, green: 0.83, blue: 0.40)
}

extension View {
    /// Latin anime titles read left-to-right even inside the RTL interface.
    func latin() -> some View { environment(\.layoutDirection, .leftToRight) }
}

// MARK: - Navigation

enum Route: Hashable {
    case detail(Anime, autoplay: Bool)
    case list(String, [Anime])
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .detail(let anime, let autoplay):
                DetailView(anime: anime, autoplay: autoplay)
            case .list(let title, let items):
                GridListView(title: title, items: items)
            }
        }
    }
}

// MARK: - Remote image (sends the site Referer, cached)

final class ImageStore {
    static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 500
        return c
    }()
}

struct RemoteImage: View {
    let url: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.card)
                if failed {
                    Image(systemName: "photo").font(.title3).foregroundStyle(Theme.muted)
                }
            }
        }
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        guard !url.isEmpty, let u = URL(string: url) else { failed = true; return }
        if let cached = ImageStore.cache.object(forKey: u as NSURL) { image = cached; return }
        var req = URLRequest(url: u)
        req.setValue(providerReferer, forHTTPHeaderField: "Referer")
        req.setValue(providerUA, forHTTPHeaderField: "User-Agent")
        if let res = try? await URLSession.shared.data(for: req), let img = UIImage(data: res.0) {
            ImageStore.cache.setObject(img, forKey: u as NSURL)
            image = img
        } else {
            failed = true
        }
    }
}

struct Poster: View {
    let anime: Anime
    var width: CGFloat = 112

    var body: some View {
        Color.clear
            .frame(width: width, height: width * 1.5)
            .overlay(RemoteImage(url: anime.image))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ErrorView: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(Theme.muted)
            Text(text).multilineTextAlignment(.center)
            Button("إعادة المحاولة", action: retry)
                .font(.headline)
                .padding(.horizontal, 22).padding(.vertical, 9)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.black)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - Root (tab bar)

struct RootView: View {
    @EnvironmentObject var catalog: CatalogStore

    var body: some View {
        TabView {
            NavigationStack { HomeView().withRoutes() }
                .tabItem { Label("الرئيسية", systemImage: "house.fill") }
            NavigationStack { SearchView().withRoutes() }
                .tabItem { Label("بحث", systemImage: "magnifyingglass") }
            AccountView(showsDone: false)
                .tabItem { Label("حسابي", systemImage: "person.crop.circle") }
        }
        .tint(.white)
        .task { await catalog.load() }
    }
}

// MARK: - Home

struct ContinueItem: Identifiable {
    let anime: Anime
    let episode: String
    var id: String { anime.id }
}

struct HomeView: View {
    @EnvironmentObject var catalog: CatalogStore
    @EnvironmentObject var history: HistoryStore

    private var continuing: [ContinueItem] {
        history.entries.compactMap { entry in
            catalog.anime(id: entry.animeID).map { ContinueItem(anime: $0, episode: entry.episode) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let featured = catalog.featured {
                    HeroView(anime: featured)
                }
                if let error = catalog.error, catalog.items.isEmpty {
                    ErrorView(text: error) { Task { await catalog.load(force: true) } }
                        .padding(.top, 140)
                }
                if !continuing.isEmpty {
                    ContinueRow(items: continuing)
                }
                if !catalog.newest.isEmpty {
                    PosterRow(title: "أُضيف حديثاً", items: catalog.newest)
                }
                ForEach(catalog.yearRows) { row in
                    PosterRow(title: "أنمي \(row.id)", items: row.items)
                }
                if !catalog.classics.isEmpty {
                    PosterRow(title: "كلاسيكيات", items: catalog.classics)
                }
                if !catalog.items.isEmpty {
                    PosterRow(title: "كل الأنمي", items: catalog.items)
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.bg.ignoresSafeArea())
        .overlay {
            if catalog.loading && catalog.items.isEmpty {
                ProgressView().controlSize(.large).tint(Theme.accent)
            }
        }
        .refreshable { await catalog.load(force: true) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("VELMIRA")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: .black.opacity(0.6), radius: 6)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HeroView: View {
    let anime: Anime

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(height: 540)
                .overlay(RemoteImage(url: anime.image))
                .clipped()
            LinearGradient(colors: [.clear, Theme.bg.opacity(0.65), Theme.bg],
                           startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
            LinearGradient(colors: [Color.black.opacity(0.7), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22))
            VStack(spacing: 12) {
                Text(anime.name)
                    .font(.system(size: 30, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.8), radius: 8)
                    .latin()
                HStack(spacing: 8) {
                    if !anime.year.isEmpty {
                        Text(anime.year)
                    }
                    if !anime.status.isEmpty {
                        Text("•")
                        Text(anime.status)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.85))
                HStack(spacing: 12) {
                    NavigationLink(value: Route.detail(anime, autoplay: true)) {
                        Label("تشغيل", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(Color.black)
                    }
                    NavigationLink(value: Route.detail(anime, autoplay: false)) {
                        Label("معلومات", systemImage: "info.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(Color.white)
                    }
                }
                .padding(.horizontal, 36)
            }
            .padding(.bottom, 16)
        }
        .frame(height: 540)
    }
}

struct PosterRow: View {
    let title: String
    let items: [Anime]
    var limit = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                if items.count > limit {
                    NavigationLink(value: Route.list(title, items)) {
                        HStack(spacing: 3) {
                            Text("عرض الكل")
                            Image(systemName: "chevron.left")
                        }
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(items.prefix(limit)) { anime in
                        NavigationLink(value: Route.detail(anime, autoplay: false)) {
                            Poster(anime: anime)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

struct ContinueRow: View {
    let items: [ContinueItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("متابعة المشاهدة").font(.title3.bold()).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(items) { item in
                        NavigationLink(value: Route.detail(item.anime, autoplay: true)) {
                            VStack(spacing: 0) {
                                Poster(anime: item.anime, width: 120)
                                    .overlay {
                                        Image(systemName: "play.circle")
                                            .font(.system(size: 40, weight: .light))
                                            .foregroundStyle(Color.white)
                                            .shadow(radius: 6)
                                    }
                                HStack {
                                    Text("الحلقة \(item.episode)").font(.caption.bold())
                                    Spacer()
                                    Image(systemName: "ellipsis").font(.caption)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .frame(width: 120)
                                .background(Theme.card)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

// MARK: - Grid list / Search

struct AnimeGrid: View {
    let items: [Anime]
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(items) { anime in
                NavigationLink(value: Route.detail(anime, autoplay: false)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Color.clear
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .overlay(RemoteImage(url: anime.image))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(anime.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .latin()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }
}

struct GridListView: View {
    let title: String
    let items: [Anime]

    var body: some View {
        ScrollView { AnimeGrid(items: items).padding(.vertical, 10) }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct SearchView: View {
    @EnvironmentObject var catalog: CatalogStore
    @State private var query = ""

    private var results: [Anime] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? catalog.newest : catalog.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(query.isEmpty ? "الأحدث" : "النتائج (\(results.count))")
                    .font(.title3.bold())
                    .padding(.horizontal, 14)
                if !query.isEmpty && results.isEmpty {
                    Text("لا توجد نتائج لـ «\(query)»")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
                AnimeGrid(items: results)
            }
            .padding(.vertical, 10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("بحث")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "ابحث عن أنمي")
    }
}

// MARK: - Detail

struct PlayItem: Identifiable {
    let id = UUID()
    let url: URL
    let cookie: String
    let title: String
}

struct DetailView: View {
    let anime: Anime
    let autoplay: Bool
    @EnvironmentObject var session: Session
    @EnvironmentObject var catalog: CatalogStore
    @EnvironmentObject var history: HistoryStore
    @State private var episodes: [Episode] = []
    @State private var loading = true
    @State private var error: String?
    @State private var preparing: String?
    @State private var playing: PlayItem?
    @State private var showAccount = false
    @State private var didAutoplay = false

    private var lastWatched: String? { history.lastEpisode(of: anime.id) }

    private var resumeEpisode: Episode? {
        if let n = lastWatched, let ep = episodes.first(where: { $0.number == n }) { return ep }
        return episodes.first
    }

    private var playLabel: String {
        guard let ep = resumeEpisode else { return "تشغيل" }
        return lastWatched == nil ? "تشغيل الحلقة \(ep.number)" : "متابعة الحلقة \(ep.number)"
    }

    private var similar: [Anime] {
        Array(catalog.items.filter { $0.year == anime.year && $0.id != anime.id }.prefix(20))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                info
                if let error {
                    ErrorView(text: error) { Task { await load() } }
                }
                episodesSection
                if !similar.isEmpty {
                    PosterRow(title: "أعمال من نفس السنة", items: similar)
                        .padding(.top, 8)
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.bg.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { if episodes.isEmpty { await load() } }
        .fullScreenCover(item: $playing) { PlayerScreen(item: $0) }
        .sheet(isPresented: $showAccount) {
            AccountView(showsDone: true).environmentObject(session)
        }
    }

    private var header: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(height: 330)
                .overlay(RemoteImage(url: anime.image).blur(radius: 22).opacity(0.6))
                .clipped()
            LinearGradient(colors: [.clear, Theme.bg], startPoint: .center, endPoint: .bottom)
            Poster(anime: anime, width: 160)
                .shadow(color: .black.opacity(0.7), radius: 18, y: 10)
        }
        .frame(height: 330)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(anime.name)
                .font(.title2.weight(.heavy))
                .frame(maxWidth: .infinity, alignment: .leading)
                .latin()
            HStack(spacing: 10) {
                if !anime.year.isEmpty {
                    Text(anime.year).foregroundStyle(Theme.match).bold()
                }
                if !anime.status.isEmpty {
                    Text(anime.status)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.muted, lineWidth: 1))
                }
                Text("HD")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.muted, lineWidth: 1))
                if !episodes.isEmpty {
                    Text("\(episodes.count) حلقة")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.white.opacity(0.85))

            Button {
                if let ep = resumeEpisode { Task { await play(ep) } }
            } label: {
                HStack {
                    if preparing != nil && preparing == resumeEpisode?.id {
                        ProgressView().tint(Color.black)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(playLabel)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.black)
            }
            .disabled(episodes.isEmpty || preparing != nil)

            if !session.isLoggedIn {
                Button {
                    showAccount = true
                } label: {
                    Label("سجّل الدخول للمشاهدة", systemImage: "person.badge.key")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("الحلقات").font(.headline)
                Rectangle().fill(Theme.accent).frame(width: 64, height: 4)
            }
            if loading {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                    .padding(.vertical, 30)
            }
            LazyVStack(spacing: 14) {
                ForEach(episodes) { ep in
                    episodeRow(ep)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func episodeRow(_ ep: Episode) -> some View {
        Button {
            Task { await play(ep) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Color.clear
                        .frame(width: 136, height: 77)
                        .overlay(RemoteImage(url: ep.image.isEmpty ? anime.image : ep.image))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if preparing == ep.id {
                        ProgressView().tint(Color.white)
                    } else {
                        Image(systemName: "play.circle")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Color.white)
                            .shadow(radius: 4)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("الحلقة \(ep.number)").font(.subheadline.bold())
                    if !ep.name.isEmpty && ep.name != ep.number {
                        Text(ep.name).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                    if lastWatched == ep.number {
                        Text("آخر ما شاهدت").font(.caption2.bold()).foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(preparing != nil)
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        var path = "/v2/anime/\(enc(anime.id))/episodes?title=\(enc(anime.name))"
        if !anime.year.isEmpty { path += "&year=\(enc(anime.year))" }
        do {
            let obj = try await API.request(path)
            let rows = obj["result"] as? [[String: Any]] ?? []
            episodes = rows.enumerated().compactMap { Episode($0.element, index: $0.offset) }
            if episodes.isEmpty { error = "لا توجد حلقات متاحة" }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        if autoplay && !didAutoplay, let ep = resumeEpisode {
            didAutoplay = true
            await play(ep)
        }
    }

    @MainActor
    private func play(_ ep: Episode) async {
        guard let token = session.token, !token.isEmpty else { showAccount = true; return }
        preparing = ep.id
        defer { preparing = nil }
        let quality = UserDefaults.standard.string(forKey: "quality") ?? "2"
        do {
            let target = try await API.resolveVideo(epID: ep.id, quality: quality, token: token)
            history.record(animeID: anime.id, episode: ep.number)
            playing = PlayItem(url: target.url, cookie: target.cookie, title: "\(anime.name) - الحلقة \(ep.number)")
        } catch APIError.unauthorized {
            session.logout()
            error = "انتهت الجلسة، سجّل الدخول من جديد"
            showAccount = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Account & settings

struct AccountView: View {
    let showsDone: Bool
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var login = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @AppStorage("quality") private var quality = "2"
    @AppStorage("base") private var base = API.defaultBase

    var body: some View {
        NavigationStack {
            Form {
                if session.isLoggedIn {
                    Section("الحساب") {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.accent)
                                .frame(width: 52, height: 52)
                                .overlay(Text(String(session.username.prefix(1)).uppercased())
                                    .font(.title2.bold()))
                            VStack(alignment: .leading) {
                                Text(session.username.isEmpty ? "مسجّل الدخول" : session.username).font(.headline)
                                Text("Velmira").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        Button("تسجيل الخروج", role: .destructive) { session.logout() }
                    }
                } else {
                    Section {
                        TextField("اسم المستخدم أو البريد", text: $login)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                        SecureField("كلمة المرور", text: $password)
                            .textContentType(.password)
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(Theme.accent)
                        }
                        Button {
                            Task { await doLogin() }
                        } label: {
                            HStack {
                                Spacer()
                                if busy {
                                    ProgressView().tint(Color.white)
                                } else {
                                    Text("تسجيل الدخول").bold()
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Theme.accent)
                        .foregroundStyle(Color.white)
                        .disabled(busy || login.isEmpty || password.isEmpty)
                    } header: {
                        Text("تسجيل الدخول")
                    } footer: {
                        Text("نفس حسابك في Velmira. التصفح لا يحتاج حساب، المشاهدة تحتاج.")
                    }
                }

                Section("التشغيل") {
                    Picker("الجودة", selection: $quality) {
                        Text("افتراضي (2)").tag("2")
                        Text("قيمة 1").tag("1")
                        Text("قيمة 3").tag("3")
                    }
                }

                Section("الخادم") {
                    TextField("رابط Worker", text: $base)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .latin()
                    Button("استعادة الرابط الافتراضي") { base = API.defaultBase }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("حسابي")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if showsDone {
                        Button("تم") { dismiss() }
                    }
                }
            }
        }
    }

    @MainActor
    private func doLogin() async {
        busy = true
        error = nil
        do {
            try await session.login(login.trimmingCharacters(in: .whitespaces), password)
            password = ""
            if showsDone { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
