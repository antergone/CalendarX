import XCTest
@testable import CalendarXLib

final class TiaoxiuStoreTests: XCTestCase {

    @MainActor
    func testSuccessfulUpdatePersistsAndReloads() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let userDefaultsSuite = "CalendarX.TiaoxiuStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let payload = Data(
            #"{"2027":{"0101":2,"0102":2,"0201":1}}"#.utf8
        )
        let store = TiaoxiuStore(
            storageDirectory: directory,
            userDefaults: userDefaults,
            fetcher: { _ in
                DownloadedTiaoxiuData(statusCode: 200, body: payload, etag: #""v1""#)
            }
        )

        let result = await store.update()

        guard case .success(.updated) = result else {
            return XCTFail("Expected the remote data to be saved")
        }
        XCTAssertEqual(store.source, .remote)
        XCTAssertEqual(store.tiaoxiu(year: "2027", monthDay: "0101"), .xiu)
        XCTAssertEqual(store.tiaoxiu(year: "2027", monthDay: "0201"), .ban)
        XCTAssertEqual(store.tiaoxiu(year: "2026", monthDay: "0101"), .xiu)

        let reloadedStore = TiaoxiuStore(
            storageDirectory: directory,
            userDefaults: userDefaults,
            fetcher: { _ in throw TiaoxiuUpdateError.network }
        )
        XCTAssertEqual(reloadedStore.source, .remote)
        XCTAssertEqual(reloadedStore.tiaoxiu(year: "2027", monthDay: "0101"), .xiu)

        XCTAssertTrue(reloadedStore.restoreBundledData())
        XCTAssertEqual(reloadedStore.source, .bundled)
        XCTAssertEqual(reloadedStore.tiaoxiu(year: "2027", monthDay: "0101"), .xiu)
    }

    @MainActor
    func testInvalidRemoteDataKeepsBundledData() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let userDefaultsSuite = "CalendarX.TiaoxiuStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let invalidPayload = Data(
            #"{"2027":{"0231":2}}"#.utf8
        )
        let store = TiaoxiuStore(
            storageDirectory: directory,
            userDefaults: userDefaults,
            fetcher: { _ in
                DownloadedTiaoxiuData(statusCode: 200, body: invalidPayload, etag: nil)
            }
        )

        let result = await store.update()

        guard case .failure(.invalidData) = result else {
            return XCTFail("Expected invalid data to be rejected")
        }
        XCTAssertEqual(store.source, .bundled)
        XCTAssertEqual(store.tiaoxiu(year: "2026", monthDay: "0101"), .xiu)
        XCTAssertEqual(store.tiaoxiu(year: "2027", monthDay: "0101"), .xiu)
    }

    @MainActor
    func testRemoteURLPersistsAndCanReset() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let userDefaultsSuite = "CalendarX.TiaoxiuStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let store = TiaoxiuStore(
            storageDirectory: directory,
            userDefaults: userDefaults
        )
        let customURL = "https://example.com/calendarx/tiaoxiu.json"

        XCTAssertTrue(store.setRemoteURL(customURL))
        XCTAssertEqual(store.remoteURL.absoluteString, customURL)

        let reloadedStore = TiaoxiuStore(
            storageDirectory: directory,
            userDefaults: userDefaults
        )
        XCTAssertEqual(reloadedStore.remoteURL.absoluteString, customURL)

        reloadedStore.resetRemoteURL()
        XCTAssertEqual(reloadedStore.remoteURL, TiaoxiuStore.defaultRemoteURL)
        XCTAssertFalse(store.setRemoteURL("http://example.com/tiaoxiu.json"))
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("CalendarX-TiaoxiuTests-\(UUID().uuidString)", isDirectory: true)
}
