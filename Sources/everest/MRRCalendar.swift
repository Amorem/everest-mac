import Foundation
import Security

/// MRRCalendar (mrrcalendar.com): MRR, revenue and daily commits for live
/// DisplayPad keys, read from `GET /api/public/v1/metrics` with a personal
/// access token (`mrrc_…`, created in MRRCalendar under Account ›
/// Integrations). The token lives in the login keychain; the last answer is
/// cached in the config directory so the app and the daemon share it and a
/// restart shows numbers at once. Fetched at most every five minutes.
enum MRRCalendar {
    struct Metrics: Codable, Equatable {
        struct Point: Codable, Equatable { var date: String; var value: Double }
        struct Count: Codable, Equatable { var date: String; var count: Int }
        struct Revenue: Codable, Equatable { var today: Double; var last30Days: Double; var daily: [Point] }
        struct Commits: Codable, Equatable {
            var available: Bool
            var today: Int
            var last30Days: Int
            var maxDaily: Int
            var daily: [Count]
        }
        struct Trends: Codable, Equatable { var mrr: Double; var revenue: Double }

        var currency: String
        var generatedAt: String
        var today: String
        var mrr: Double
        var arr: Double
        var activeSubscriptions: Int
        var revenue: Revenue
        var commits: Commits
        var trends: Trends
    }

    static let defaultBaseURL = "https://mrrcalendar.com"
    static let refreshInterval: TimeInterval = 300

    // MARK: Token (login keychain)

    private static let service = "local.everest-mac.mrrcalendar"
    private static let account = "personal-access-token"

    static var token: String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Store (or, with nil / empty, remove) the token.
    @discardableResult
    static func setToken(_ value: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        cache = nil
        try? FileManager.default.removeItem(at: cacheURL)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static var isConfigured: Bool { token != nil }

    // MARK: Fetching

    enum FetchError: Error, Equatable {
        case notConfigured
        case unauthorized
        case http(Int)
        case network(String)
        case decoding
    }

    private static let lock = NSLock()
    private static var cache: (metrics: Metrics, fetchedAt: Date)?
    private static var inFlight = false
    private(set) static var lastError: FetchError?

    static var cacheURL: URL { Config.directory.appendingPathComponent(".mrrcalendar.json") }

    /// The latest numbers without waiting: from memory or the cache file,
    /// and a refresh started in the background when they are older than
    /// five minutes. nil until the first answer.
    static func latest(now: Date = Date()) -> Metrics? {
        lock.lock()
        if cache == nil, let data = try? Data(contentsOf: cacheURL),
           let metrics = try? JSONDecoder().decode(Metrics.self, from: data) {
            let date = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
            cache = (metrics, date ?? .distantPast)
        }
        let current = cache
        let stale = current.map { now.timeIntervalSince($0.fetchedAt) > refreshInterval } ?? true
        let start = stale && !inFlight
        if start { inFlight = true }
        lock.unlock()
        if start {
            Task.detached {
                _ = await refresh()
                lock.lock(); inFlight = false; lock.unlock()
            }
        }
        return current?.metrics
    }

    /// Fetch now (also used by the app's "Test" button).
    @discardableResult
    static func refresh() async -> Result<Metrics, FetchError> {
        let result = await fetch()
        lock.lock()
        switch result {
        case .success(let metrics):
            cache = (metrics, Date())
            lastError = nil
            if let data = try? JSONEncoder().encode(metrics) {
                try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        case .failure(let error):
            lastError = error
        }
        lock.unlock()
        return result
    }

    static func fetch(baseURL: String = Config.load().mrrCalendarURL) async -> Result<Metrics, FetchError> {
        guard let token, let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/api/public/v1/metrics") else {
            return .failure(.notConfigured)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("everest-mac", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return .failure(.unauthorized) }
            guard status == 200 else { return .failure(.http(status)) }
            guard let metrics = try? JSONDecoder().decode(Metrics.self, from: data) else { return .failure(.decoding) }
            return .success(metrics)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: Display

    /// "€4.2k", "$980", "1.2M €" — short enough for a 102 px key.
    static func compactMoney(_ value: Double, currency: String) -> String {
        let symbols = ["EUR": "€", "USD": "$", "GBP": "£", "CHF": "CHF ", "CAD": "CA$", "JPY": "¥"]
        let symbol = symbols[currency.uppercased()] ?? "\(currency.uppercased()) "
        let a = abs(value)
        let number: String
        switch a {
        case 1_000_000...: number = String(format: a >= 10_000_000 ? "%.0fM" : "%.1fM", value / 1_000_000)
        case 10_000...: number = String(format: "%.0fk", value / 1_000)
        case 1_000...: number = String(format: "%.1fk", value / 1_000)
        default: number = String(format: "%.0f", value)
        }
        return symbol + number.replacingOccurrences(of: ".0k", with: "k").replacingOccurrences(of: ".0M", with: "M")
    }
}
