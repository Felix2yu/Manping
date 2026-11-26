import Foundation
import XCTest
@testable import ManpingCore

final class M8AIStoreTests: XCTestCase {
  private func turn(_ text: String) -> AITurn {
    AITurn(presetID: "qa", presetName: "问答", question: "q", content: .markdown(text), rawText: text, materials: [.subtitles],
      model: "m", provider: "p")
  }

  func testSingleUserTicketsAndClear() throws {
    let store = try AIConversationStore(url: nil)
    XCTAssertEqual(store.currentOwner, AIConversationStore.anonymous)
    let ticket = store.ticket()
    var thread = AIThread(sourceKey: "video:1:2", title: "t"); thread.turns = [turn("回答")]
    XCTAssertTrue(try store.save(thread, ticket: ticket))
    XCTAssertTrue(try store.save(answer: AIStoredAnswer(content: .markdown("x"), rawText: "x", materials: [], notes: [], createdAt: Date()),
      key: "k", ticket: ticket))
    XCTAssertTrue(try store.save(segment: "seg", key: "s", ticket: ticket))
    XCTAssertEqual(try store.threads(sourceKey: "video:1:2", ticket: ticket).first?.turns.first?.rawText, "回答")
    XCTAssertEqual(try store.segment(key: "s", ticket: ticket), "seg")
    try store.clearAll()
    XCTAssertFalse(store.isCurrent(ticket))
    XCTAssertEqual(try store.threads(sourceKey: "video:1:2", ticket: ticket), [])
    XCTAssertFalse(try store.save(thread, ticket: ticket))
    XCTAssertNil(try store.answer(key: "k", ticket: store.ticket()))
  }

  func testClearInvalidatesInFlightWritersFirst() throws {
    let store = try AIConversationStore(url: nil)
    let ticket = store.ticket()
    XCTAssertTrue(try store.save(segment: "a", key: "1", ticket: ticket))
    try store.clearAll()
    // A summary that finishes after the clear cannot write its result back.
    XCTAssertFalse(try store.save(segment: "late", key: "2", ticket: ticket))
    XCTAssertNil(try store.segment(key: "1", ticket: store.ticket()))
    XCTAssertNil(try store.segment(key: "2", ticket: store.ticket()))
    let concurrent = store.ticket()
    DispatchQueue.concurrentPerform(iterations: 64) { index in
      if index == 32 { try? store.clearAll() }
      _ = try? store.save(segment: "x\(index)", key: "k\(index)", ticket: concurrent)
    }
    // Every write either landed before the clear (and was deleted) or was rejected after it.
    let after = store.ticket()
    XCTAssertTrue((0..<64).allSatisfy { (try? store.segment(key: "k\($0)", ticket: after)) == nil })
  }

  func testRowsPersistAcrossLaunchesAndExpire() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-store-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      let store = try AIConversationStore(url: url)
      XCTAssertTrue(try store.save(AIThread(sourceKey: "article:1", title: "t", updatedAt: Date(timeIntervalSince1970: 100)), ticket: store.ticket()))
      XCTAssertTrue(try store.save(AIThread(sourceKey: "article:2", title: "t"), ticket: store.ticket()))
    }
    let reopened = try AIConversationStore(url: url)
    XCTAssertEqual(reopened.currentOwner, AIConversationStore.anonymous)
    XCTAssertEqual(try reopened.usage().sources, 2)
    try reopened.purge(olderThan: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(try reopened.threads(sourceKey: "article:1", ticket: reopened.ticket()), [])
    XCTAssertEqual(try reopened.threads(sourceKey: "article:2", ticket: reopened.ticket()).count, 1)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }
}
