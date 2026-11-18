//
//  TiaoxiuStore.swift
//  CalendarXLib
//

import Combine
import Foundation

public enum TiaoxiuDataSource: String, Sendable {
    case bundled
    case remote
}

public enum TiaoxiuUpdateError: Error, Sendable, Equatable {
    case updateInProgress
    case network
    case invalidResponse
    case server
    case payloadTooLarge
    case invalidData
    case storage
}

public enum TiaoxiuUpdateResult: Sendable, Equatable {
    case updated
    case unchanged
}

struct DownloadedTiaoxiuData: Sendable {
    let statusCode: Int
    let body: Data
    let etag: String?
}

typealias TiaoxiuDataFetcher = @Sendable (URLRequest) async throws -> DownloadedTiaoxiuData

@MainActor
public final class TiaoxiuStore: ObservableObject {

    public static let shared = TiaoxiuStore()

    public nonisolated static let defaultRemoteURL = URL(
        string: "https://raw.githubusercontent.com/antergone/CalendarX/master/CalendarXLib/Sources/Resources/festival_solar_tiaoxiu.json"
    )!

    @Published
    public private(set) var remoteURL: URL

    @Published
    public private(set) var source: TiaoxiuDataSource

    @Published
    public private(set) var lastUpdated: Date?

    @Published
    public private(set) var isUpdating = false

    public var years: [Int] {
        data.keys.compactMap(Int.init).sorted()
    }

    private typealias TiaoxiuData = [String: [String: Tiaoxiu]]

    private struct Metadata: Codable {
        let etag: String?
        let downloadedAt: Date
        let remoteURL: String
    }

    private let storageDirectory: URL?
    private let fetcher: TiaoxiuDataFetcher
    private let userDefaults: UserDefaults
    private let fileManager = FileManager.default
    private var data: TiaoxiuData = [:]
    private var etag: String?
    private var cachedModificationDate: Date?

    private static let cacheFilename = "festival_solar_tiaoxiu.json"
    private static let metadataFilename = "festival_solar_tiaoxiu-meta.json"
    private static let remoteURLKey = "CalendarX.tiaoxiu.remoteURL"
    private static let maximumPayloadSize = 1_048_576

    internal init(
        storageDirectory: URL? = nil,
        remoteURL: URL? = nil,
        userDefaults: UserDefaults = .standard,
        fetcher: @escaping TiaoxiuDataFetcher = { request in
            try await TiaoxiuHTTPClient.fetch(request: request)
        }
    ) {
        self.remoteURL =
            remoteURL
            ?? userDefaults.string(forKey: Self.remoteURLKey).flatMap(Self.validatedRemoteURL)
            ?? Self.defaultRemoteURL
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory
        self.fetcher = fetcher
        self.userDefaults = userDefaults
        self.source = .bundled
        self.lastUpdated = nil

        if let storageDirectory = self.storageDirectory {
            try? fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
        }
        loadStoredData()
    }

    public func tiaoxiu(year: String, monthDay: String) -> Tiaoxiu {
        data[year]?[monthDay] ?? .ordinary
    }

    public var isUsingDefaultRemoteURL: Bool {
        remoteURL == Self.defaultRemoteURL
    }

    @discardableResult
    public func setRemoteURL(_ value: String) -> Bool {
        guard let url = Self.validatedRemoteURL(value) else { return false }

        remoteURL = url
        etag = nil
        userDefaults.set(url.absoluteString, forKey: Self.remoteURLKey)
        return true
    }

    public func resetRemoteURL() {
        remoteURL = Self.defaultRemoteURL
        etag = nil
        userDefaults.removeObject(forKey: Self.remoteURLKey)
    }

    @discardableResult
    public func restoreBundledData() -> Bool {
        do {
            if let cacheURL, fileManager.fileExists(atPath: cacheURL.path) {
                try fileManager.removeItem(at: cacheURL)
            }
            if let metadataURL, fileManager.fileExists(atPath: metadataURL.path) {
                try fileManager.removeItem(at: metadataURL)
            }
            etag = nil
            cachedModificationDate = nil
            loadBundledData()
            return true
        } catch {
            return false
        }
    }

    public func reloadCachedData() {
        let modificationDate = cacheModificationDate()
        guard modificationDate != cachedModificationDate else { return }
        loadStoredData()
    }

    public func update() async -> Result<TiaoxiuUpdateResult, TiaoxiuUpdateError> {
        guard !isUpdating else { return .failure(.updateInProgress) }

        isUpdating = true
        defer { isUpdating = false }

        var request = URLRequest(
            url: remoteURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let response = try await fetcher(request)

            switch response.statusCode {
            case 304:
                return .success(.unchanged)
            case 200:
                break
            default:
                return .failure(.server)
            }

            guard response.body.count <= Self.maximumPayloadSize else {
                return .failure(.payloadTooLarge)
            }

            let decoded = try Self.decode(response.body)
            try persist(response.body, etag: response.etag)

            data = merge(bundledData: Self.bundledData(), remoteData: decoded)
            source = .remote
            lastUpdated = Date()
            self.etag = response.etag
            cachedModificationDate = cacheModificationDate()

            return .success(.updated)
        } catch let error as TiaoxiuUpdateError {
            return .failure(error)
        } catch {
            return .failure(.network)
        }
    }
}

extension TiaoxiuStore {

    private static var defaultStorageDirectory: URL? {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "CalendarX", isDirectory: true)
            .appendingPathComponent("TiaoxiuData", isDirectory: true)

        return directory
    }

    private var cacheURL: URL? {
        storageDirectory?.appendingPathComponent(Self.cacheFilename)
    }

    private var metadataURL: URL? {
        storageDirectory?.appendingPathComponent(Self.metadataFilename)
    }

    private func loadStoredData() {
        if let cacheURL,
            let cached = try? Data(contentsOf: cacheURL),
            let decoded = try? Self.decode(cached)
        {
            let metadata = loadMetadata()
            data = merge(bundledData: Self.bundledData(), remoteData: decoded)
            source = .remote
            lastUpdated = metadata?.downloadedAt ?? cacheModificationDate()
            etag = metadata?.remoteURL == remoteURL.absoluteString ? metadata?.etag : nil
            cachedModificationDate = cacheModificationDate()
            return
        }

        loadBundledData()
    }

    private func loadBundledData() {
        data = Self.bundledData()
        source = .bundled
        lastUpdated = nil
        etag = nil
        cachedModificationDate = nil
    }

    private func loadMetadata() -> Metadata? {
        guard let metadataURL else { return nil }
        guard let metadata = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: metadata)
    }

    private func persist(_ data: Data, etag: String?) throws {
        guard let storageDirectory, let cacheURL, let metadataURL else {
            throw TiaoxiuUpdateError.storage
        }

        do {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)

            let metadata = Metadata(
                etag: etag,
                downloadedAt: Date(),
                remoteURL: remoteURL.absoluteString
            )
            let encodedMetadata = try JSONEncoder().encode(metadata)
            try? encodedMetadata.write(to: metadataURL, options: .atomic)
        } catch {
            throw TiaoxiuUpdateError.storage
        }
    }

    private func merge(bundledData: TiaoxiuData, remoteData: TiaoxiuData) -> TiaoxiuData {
        bundledData.merging(remoteData) { _, remote in remote }
    }

    private func cacheModificationDate() -> Date? {
        guard let cacheURL else { return nil }
        return try? fileManager
            .attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
    }

    private static func decode(_ data: Data) throws -> TiaoxiuData {
        let raw: [String: [String: Int]]
        do {
            raw = try JSONDecoder().decode([String: [String: Int]].self, from: data)
        } catch {
            throw TiaoxiuUpdateError.invalidData
        }

        guard !raw.isEmpty else { throw TiaoxiuUpdateError.invalidData }

        var decoded: TiaoxiuData = [:]
        for (year, days) in raw {
            guard let yearValue = Int(year),
                year.count == 4,
                (Solar.minYear...Solar.maxYear).contains(yearValue),
                !days.isEmpty
            else {
                throw TiaoxiuUpdateError.invalidData
            }

            var decodedDays: [String: Tiaoxiu] = [:]
            for (monthDay, rawValue) in days {
                guard Self.isValidMonthDay(monthDay, year: yearValue),
                    let tiaoxiu = Tiaoxiu(rawValue: rawValue)
                else {
                    throw TiaoxiuUpdateError.invalidData
                }
                decodedDays[monthDay] = tiaoxiu
            }
            decoded[year] = decodedDays
        }
        return decoded
    }

    private static func bundledData() -> TiaoxiuData {
        Bundle.module
            .url(forResource: "festival_solar_tiaoxiu", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? Self.decode($0) }
            ?? [:]
    }

    private static func validatedRemoteURL(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false,
            let url = components.url
        else {
            return nil
        }
        return url
    }

    private static func isValidMonthDay(_ value: String, year: Int) -> Bool {
        guard value.count == 4,
            let month = Int(value.prefix(2)),
            let day = Int(value.suffix(2)),
            (1...12).contains(month),
            (1...31).contains(day)
        else {
            return false
        }

        var components = DateComponents()
        components.calendar = .gregorian
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day

        guard let date = components.date else { return false }
        let validated = Calendar.gregorian.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return validated.year == year && validated.month == month && validated.day == day
    }
}

private enum TiaoxiuHTTPClient {

    static func fetch(request: URLRequest) async throws -> DownloadedTiaoxiuData {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if error != nil {
                    continuation.resume(throwing: TiaoxiuUpdateError.network)
                    return
                }

                guard let response = response as? HTTPURLResponse else {
                    continuation.resume(throwing: TiaoxiuUpdateError.invalidResponse)
                    return
                }

                if response.expectedContentLength > 1_048_576 {
                    continuation.resume(throwing: TiaoxiuUpdateError.payloadTooLarge)
                    return
                }

                continuation.resume(
                    returning: DownloadedTiaoxiuData(
                        statusCode: response.statusCode,
                        body: data ?? Data(),
                        etag: response.value(forHTTPHeaderField: "ETag")
                    )
                )
            }.resume()
        }
    }
}
