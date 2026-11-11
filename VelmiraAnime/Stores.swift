import Foundation
import SwiftUI

// MARK: - Catalog (loaded once, shared by all tabs)

struct YearRow: Identifiable {
    let id: String          // the year
    let items: [Anime]
}

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var items: [Anime] = []
    @Published private(set) var newest: [Anime] = []
    @Published private(set) var yearRows: [YearRow] = []
    @Published private(set) var classics: [Anime] = []
    @Published private(set) var featured: Anime?
    @Published private(set) var loading = false
    @Published var error: String?

    private var byID: [String: Anime] = [:]

    func anime(id: String) -> Anime? { byID[id] }

    func load(force: Bool = false) async {
        if loading { return }
        if !items.isEmpty && !force { return }
        loading = true
        error = nil
        do {
            let obj = try await API.request("/v2/anime")
            let rows = obj["result"] as? [[String: Any]] ?? []
            let list = rows.compactMap { Anime($0) }
            apply(list)
            if list.isEmpty { error = "لا توجد عناصر" }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func apply(_ list: [Anime]) {
        items = list
        var map: [String: Anime] = [:]
        for a in list { map[a.id] = a }
        byID = map

        func y(_ a: Anime) -> Int { Int(a.year) ?? 0 }
        newest = list.sorted { y($0) > y($1) }

        let years = Set(list.map(\.year).filter { !$0.isEmpty })
            .sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
        yearRows = years.prefix(4).map { year in
            YearRow(id: year, items: list.filter { $0.year == year })
        }
        classics = list.filter { (Int($0.year) ?? 9999) < 2010 }

        let pool = newest.prefix(20).filter { !$0.image.isEmpty }
        featured = pool.randomElement() ?? list.first
    }
}

// MARK: - Watch history ("متابعة المشاهدة")

struct WatchEntry: Codable, Hashable {
    let animeID: String
    let episode: String
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [WatchEntry] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "history"),
           let saved = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            entries = saved
        }
    }

    func record(animeID: String, episode: String) {
        entries.removeAll { $0.animeID == animeID }
        entries.insert(WatchEntry(animeID: animeID, episode: episode), at: 0)
        if entries.count > 30 { entries = Array(entries.prefix(30)) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "history")
        }
    }

    func lastEpisode(of animeID: String) -> String? {
        entries.first { $0.animeID == animeID }?.episode
    }
}
