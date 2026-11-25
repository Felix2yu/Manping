import AppKit
import XCTest
@testable import ManpingApp

final class MpvEnginePoolBudgetTests: XCTestCase {
  private let mib = MpvParkingBudget.bytesPerMiB
  private let gib: UInt64 = 1 << 30

  func testDefaultBudgetReflectsPhysicalMemory() {
    XCTAssertEqual(MpvParkingBudget.configuredBytes(physicalMemory: 4 * gib, environment: [:]), 128 * mib)
    XCTAssertEqual(MpvParkingBudget.configuredBytes(physicalMemory: 8 * gib, environment: [:]), 128 * mib)
    XCTAssertEqual(MpvParkingBudget.configuredBytes(physicalMemory: 16 * gib, environment: [:]), 256 * mib)
  }

  func testEnvironmentOverridesBudget() {
    let environment = ["MANPING_MPV_POOL_BUDGET_MIB": "384"]
    XCTAssertEqual(MpvParkingBudget.configuredBytes(physicalMemory: 16 * gib, environment: environment), 384 * mib)
    XCTAssertEqual(MpvParkingBudget.configuredBytes(physicalMemory: 8 * gib, environment: environment), 384 * mib)
    XCTAssertEqual(
      MpvParkingBudget.configuredBytes(physicalMemory: 16 * gib,
        environment: ["MANPING_MPV_POOL_BUDGET_MIB": "64"]), 64 * mib)
  }

  func testInvalidEnvironmentOverrideUsesDefault() {
    for value in ["", "0", "0.5", "-1", "nan", "inf", "invalid", "999999999999999999999"] {
      let environment = ["MANPING_MPV_POOL_BUDGET_MIB": value]
      XCTAssertEqual(MpvParkingBudget.configuredBytes(physicalMemory: 8 * gib, environment: environment), 128 * mib)
      XCTAssertEqual(MpvParkingBudget.configuredBytes(physicalMemory: 16 * gib, environment: environment), 256 * mib)
    }
  }

  func testEstimateIncludesEngineLayerAndFramebuffers() {
    let bounds = CGSize(width: 1920, height: 1080)
    let pixels = UInt64(1920 * 1080)
    XCTAssertEqual(
      MpvParkingBudget.estimate(bounds: bounds, contentsFormat: .RGBA8Uint,
        backingScale: 1, floating: false),
      32 * mib + pixels * (4 + 2 * 4))
    XCTAssertEqual(
      MpvParkingBudget.estimate(bounds: bounds, contentsFormat: .RGBA8Uint,
        backingScale: 1, floating: true),
      32 * mib + pixels * (4 + 2 * 8))
    XCTAssertEqual(
      MpvParkingBudget.estimate(bounds: bounds, contentsFormat: .RGBA16Float,
        backingScale: 1, floating: true),
      32 * mib + pixels * (8 + 2 * 8))
  }

  func testFourKFloatEstimateFitsDefaultButNotLowMemoryBudget() {
    let estimate = MpvParkingBudget.estimate(bounds: CGSize(width: 3840, height: 2160),
      contentsFormat: .RGBA16Float, backingScale: 1, floating: true)
    XCTAssertGreaterThan(estimate, 128 * mib)
    XCTAssertLessThanOrEqual(estimate, 256 * mib)
  }

  func testRetinaEstimateMatchesBackingPixelDimensions() {
    let logical = CGSize(width: 960, height: 540)
    let native = CGSize(width: 1920, height: 1080)
    XCTAssertEqual(
      MpvParkingBudget.estimate(bounds: logical, contentsFormat: .RGBA16Float,
        backingScale: 2, floating: true),
      MpvParkingBudget.estimate(bounds: native, contentsFormat: .RGBA16Float,
        backingScale: 1, floating: true))
  }

  func testEstimateRoundsPixelsAndReadsContentsFormatIndependently() {
    let bounds = CGSize(width: 10.1, height: 5.1)
    let pixels = UInt64(21 * 11)
    XCTAssertEqual(
      MpvParkingBudget.estimate(bounds: bounds, contentsFormat: .RGBA8Uint,
        backingScale: 2, floating: true),
      32 * mib + pixels * (4 + 2 * 8))
    XCTAssertEqual(
      MpvParkingBudget.estimate(bounds: bounds, contentsFormat: .RGBA16Float,
        backingScale: 2, floating: true),
      32 * mib + pixels * (8 + 2 * 8))
  }

  func testInvalidGeometryUsesEngineOverheadAndInvalidScaleUsesOne() {
    for bounds in [
      CGSize(width: 0, height: 1080), CGSize(width: 1920, height: -1),
      CGSize(width: CGFloat.nan, height: 1080), CGSize(width: 1920, height: CGFloat.infinity),
    ] {
      XCTAssertEqual(
        MpvParkingBudget.estimate(bounds: bounds, contentsFormat: .RGBA16Float,
          backingScale: 2, floating: true), 32 * mib)
    }
    let bounds = CGSize(width: 1920, height: 1080)
    let expected = MpvParkingBudget.estimate(bounds: bounds, contentsFormat: .RGBA8Uint,
      backingScale: 1, floating: true)
    for scale: CGFloat in [0, -2, .nan, .infinity] {
      XCTAssertEqual(
        MpvParkingBudget.estimate(bounds: bounds, contentsFormat: .RGBA8Uint,
          backingScale: scale, floating: true), expected)
    }
  }
}
