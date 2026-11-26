import Foundation
import XCTest

@testable import ManpingApp

final class LocalSubtitleFileTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Manping-Subtitle-Tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try FileManager.default.removeItem(at: directory) }
  }

  func testStagesSRTAndASSCopiesWithPrivateDirectory() throws {
    for format in ["srt", "ASS"] {
      let source = directory.appendingPathComponent("sample." + format)
      let content = Data("1\n00:00:01,000 --> 00:00:02,000\n字幕\n".utf8)
      try content.write(to: source)
      let staged = try LocalSubtitleFile.stage(source)
      defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
      XCTAssertEqual(staged.pathExtension.lowercased(), format.lowercased())
      XCTAssertEqual(try Data(contentsOf: staged), content)
      let attributes = try FileManager.default.attributesOfItem(
        atPath: staged.deletingLastPathComponent().path)
      XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }
  }

  func testRejectsSpoofedExtensionAndSymlink() throws {
    let text = directory.appendingPathComponent("not-subtitle.txt")
    try Data("subtitle".utf8).write(to: text)
    let disguised = directory.appendingPathComponent("sample.srt")
    try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: text)
    for source in [text, disguised] {
      XCTAssertThrowsError(try LocalSubtitleFile.stage(source)) { error in
        XCTAssertTrue(error is LocalSubtitleFile.Failure)
      }
    }
  }

  func testAcceptsFileAtTheExactSizeLimit() throws {
    let source = directory.appendingPathComponent("limit.srt")
    let content = Data(repeating: 65, count: 100)
    try content.write(to: source)
    let staged = try LocalSubtitleFile.stage(source, maximumBytes: 100)
    defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
    XCTAssertEqual(try Data(contentsOf: staged), content)
  }
  func testRejectsEmptyAndOversizedFiles() throws {
    let empty = directory.appendingPathComponent("empty.srt")
    try Data().write(to: empty)
    XCTAssertThrowsError(try LocalSubtitleFile.stage(empty))
    let large = directory.appendingPathComponent("large.srt")
    try Data(repeating: 65, count: 101).write(to: large)
    XCTAssertThrowsError(try LocalSubtitleFile.stage(large, maximumBytes: 100)) { error in
      guard let failure = error as? LocalSubtitleFile.Failure, case .tooLarge = failure else {
        return XCTFail("Expected size error, got \(error)")
      }
    }
  }
}
