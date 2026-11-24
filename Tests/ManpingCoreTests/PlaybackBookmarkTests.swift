import Foundation
import XCTest
@testable import ManpingCore

final class PlaybackBookmarkTests: XCTestCase {
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("playback-bookmarks-\(UUID().uuidString)", isDirectory: true)
  }

  func testMediaIdentityPrefersAIDAndCIDThenFallsBackToBVID() throws {
    let primary = try PlaybackBookmarkMediaKey(aid: 10, cid: 20, bvid: "BV1xx411c7mD")
    let missingAID = try PlaybackBookmarkMediaKey(aid: nil, cid: 20, bvid: "BV1xx411c7mD")
    let missingCID = try PlaybackBookmarkMediaKey(aid: 10, cid: nil, bvid: "BV1xx411c7mD")
    XCTAssertEqual(primary.rawValue, "10:20")
    XCTAssertEqual(missingAID, primary)
    XCTAssertEqual(missingCID.rawValue, "bvid:BV1xx411c7mD")
    XCTAssertEqual(try PlaybackBookmarkMediaKey(rawValue: "10:20"), primary)
    XCTAssertNil(PlaybackBookmarkMediaKey(rawValue: "bvid:BV1xx411c7d"))
    XCTAssertNil(PlaybackBookmarkMediaKey(rawValue: "10:0"))
    XCTAssertThrowsError(try PlaybackBookmarkMediaKey(aid: nil, cid: nil, bvid: "bad"))
  }

  func testModelRejectsInvalidTimesAndLongNotes() throws {
    let media = try PlaybackBookmarkMediaKey(aid: 1, cid: 2, bvid: "BV1xx411c7mD")
    let note = String(repeating: "笔", count: PlaybackBookmark.maximumNoteLength)
    let bookmark = try PlaybackBookmark(mediaKey: media, time: 0, note: note)
    XCTAssertEqual(bookmark.note.count, 2_000)
    for time in [-1, .infinity, .nan, -.infinity] {
      XCTAssertThrowsError(try PlaybackBookmark(mediaKey: media, time: time))
    }
    XCTAssertThrowsError(try PlaybackBookmark(mediaKey: media, time: 1, note: note + "记"))
    XCTAssertThrowsError(try bookmark.updating(time: 1, note: "both"))
    XCTAssertThrowsError(try bookmark.updating(time: .nan))
    XCTAssertThrowsError(try bookmark.updating(note: note + "记"))
    let edited = try bookmark.updating(note: "修改")
    XCTAssertEqual(edited.id, bookmark.id)
    XCTAssertEqual(edited.time, bookmark.time)
    XCTAssertEqual(edited.note, "修改")
  }

  func testPersistenceIsVersionedAtomicAndVerifiedOnReadBack() throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("bookmarks.json")
    let media = try PlaybackBookmarkMediaKey(aid: 7, cid: 8, bvid: "BV1xx411c7mD")
    let store = try PlaybackBookmarkStore(url: url)
    XCTAssertTrue(store.isEmpty)
    let first = try store.add(time: 12.5, note: "第二个时间点", to: media)
    let second = try store.add(time: 3, to: media)
    XCTAssertEqual(store.bookmarks(for: media).map(\.id), [second.id, first.id])
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let document = try decoder.decode(PlaybackBookmarkDocument.self, from: data)
    XCTAssertEqual(document.version, 1)
    XCTAssertEqual(document.bookmarks[media.rawValue]?.count, 2)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".bookmarks.json.tmp").path))

    let reopened = try PlaybackBookmarkStore(url: url)
    XCTAssertEqual(reopened.bookmarks(for: media), store.bookmarks(for: media))
    let edited = try reopened.update(id: first.id, note: "更新后的笔记", in: media)
    XCTAssertEqual(edited.note, "更新后的笔记")
    XCTAssertEqual(try PlaybackBookmarkStore(url: url).bookmarks(for: media).first(where: { $0.id == first.id })?.note,
      "更新后的笔记")
    try reopened.remove(id: first.id, from: media)
    XCTAssertEqual(try PlaybackBookmarkStore(url: url).bookmarks(for: media).map(\.id), [second.id])
    XCTAssertThrowsError(try reopened.update(id: first.id, in: media))
    XCTAssertThrowsError(try reopened.remove(id: first.id, from: media))
  }

  func testBucketsAreIndependentAndLimitedToFiveHundred() throws {
    let media = try PlaybackBookmarkMediaKey(aid: 1, cid: 2, bvid: "BV1xx411c7mD")
    let other = try PlaybackBookmarkMediaKey(aid: 1, cid: 3, bvid: "BV1xx411c7mD")
    let store = try PlaybackBookmarkStore(memoryOnly: true)
    for time in (0..<500).reversed() { try store.add(time: Double(time), to: media) }
    XCTAssertThrowsError(try store.add(time: 500, to: media))
    XCTAssertEqual(store.bookmarks(for: media).count, 500)
    let separate = try store.add(time: 0, note: "另一个分 P", to: other)
    XCTAssertEqual(store.bookmarks(for: media).count, 500)
    XCTAssertEqual(store.bookmarks(for: other), [separate])
  }

  func testCorruptDocumentDoesNotOverwriteExistingUserData() throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("bookmarks.json")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    XCTAssertThrowsError(try PlaybackBookmarkStore(url: url))
    let recovered = try PlaybackBookmarkStore.recover(from: url)
    XCTAssertNotNil(recovered.loadError)
    let media = try PlaybackBookmarkMediaKey(aid: 1, cid: 2, bvid: "BV1xx411c7mD")
    XCTAssertThrowsError(try recovered.add(time: 1, to: media))
    XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "not json")
  }

  func testMalformedDiskValuesAndWrongVersionAreRejected() throws {
    let media = try PlaybackBookmarkMediaKey(aid: 1, cid: 2, bvid: "BV1xx411c7mD")
    let valid = try PlaybackBookmark(mediaKey: media, time: 1, note: "有效")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    var row = try JSONSerialization.jsonObject(with: encoder.encode(valid)) as! [String: Any]
    row["time"] = -1
    let invalidData = try JSONSerialization.data(withJSONObject: ["version": 1, "bookmarks": [media.rawValue: [row]]])
    XCTAssertThrowsError(try JSONDecoder().decode(PlaybackBookmarkDocument.self, from: invalidData))
    XCTAssertThrowsError(try JSONDecoder().decode(PlaybackBookmarkDocument.self,
      from: Data(#"{"version":2,"bookmarks":{}}"#.utf8)))
  }

  func testFailedWriteKeepsPreviousState() throws {
    let media = try PlaybackBookmarkMediaKey(aid: 1, cid: 2, bvid: "BV1xx411c7mD")
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("bookmarks.json")
    let store = try PlaybackBookmarkStore(url: url)
    let first = try store.add(time: 1, to: media)
    let original = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.add(time: 2, to: media))
    XCTAssertEqual(store.bookmarks(for: media), [first])
    try FileManager.default.removeItem(at: url)
    try original.write(to: url)
    XCTAssertEqual(try PlaybackBookmarkStore(url: url).bookmarks(for: media), [first])
  }
}
