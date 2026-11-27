#if DEBUG
import AppKit
import ManpingCore
import SwiftUI
import XCTest

@testable import ManpingApp

private final class NoCredentials: AuthCredentialStore, @unchecked Sendable {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private struct Offline: AuthTransport {
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct SearchToolbarHarness: View {
  @ObservedObject var app: AppModel
  @ObservedObject var suggestions: SearchSuggestionModel

  var body: some View {
    M3SearchBox(suggestions: suggestions, text: $app.search, suggestionsEnabled: false,
      currentScopeName: nil, active: app.browsingPageActive,
      focusRequest: app.searchFocusRequest, hotRequest: app.hotSearchRequest) { _, _ in }
      .frame(width: 360)
  }
}

/// Navigation and playback placement without online transports or native playback windows.
@MainActor final class NavigationTests: XCTestCase {
  private func model() -> AppModel {
    _ = NSApplication.shared
    let app = AppModel(probeService: BiliService(transport: Offline(), credentials: NoCredentials()), observeIdentity: false)
    app.debugSuppressPlaybackWindows = true
    app.debugSetDefaultOpenMode(.mainWindow)
    return app
  }

  private let video = Video(bvid: "", title: "Offline video", cid: 1000, aid: 100)

  private func openVideo(_ app: AppModel, mode: MacOpenMode = .mainWindow) async {
    app.open(video, mode: mode)
    await app.debugVideoLoadRequest?.value
  }

  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  /// Mini playback returns its picture to the main window; the standalone window closes and
  /// ends playback, leaving the main window on its list.
  private func closeExternalPicture(_ app: AppModel, mode: MacOpenMode) {
    if mode == .compact { app.closeMiniPlayer(activateMain: false) }
    else { app.closeDetachedPlayback() }
  }

  private func settleFocus(_ view: NSView) async throws {
    for _ in 0..<20 {
      view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func testSearchQueryIDCoversEveryRequestStateAndKeepsStringNavigation() {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.search("山野"))
    XCTAssertEqual(app.currentOverlay, .search("山野"))

    let base = LibrarySearchQuery(term: "山野")
    let original = base.queryID(refreshToken: 0)
    let variants = [
      LibrarySearchQuery(term: "新词"),
      LibrarySearchQuery(term: "山野", type: .user),
      LibrarySearchQuery(term: "山野", type: .article),
      LibrarySearchQuery(term: "山野", order: .newest),
      LibrarySearchQuery(term: "山野", userOrder: .followers),
      LibrarySearchQuery(term: "山野", userOrder: .level),
      LibrarySearchQuery(term: "山野", filters: LibraryVideoSearchFilters(duration: 1)),
      LibrarySearchQuery(term: "山野", filters: LibraryVideoSearchFilters(pubtime: 1)),
      LibrarySearchQuery(term: "山野", filters: LibraryVideoSearchFilters(tid: 161)),
    ]
    for variant in variants { XCTAssertNotEqual(variant.queryID(refreshToken: 0), original) }
    XCTAssertNotEqual(base.queryID(refreshToken: 1), original)
  }

  func testPlaybackReleasesToolbarSearchFocusWithoutDisablingLaterSearch() async throws {
    let app = model()
    defer { app.shutdown() }
    let suggestions = SearchSuggestionModel(model: app)
    let host = NSHostingView(rootView: SearchToolbarHarness(app: app, suggestions: suggestions))
    host.frame = CGRect(x: 0, y: 0, width: 600, height: 120)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    try await settleFocus(host)
    app.searchFocusRequest += 1
    try await settleFocus(host)
    XCTAssertTrue(PlaybackKeyboardInput.blocksShortcut(window.firstResponder), "fixture must start with the search editor focused")

    await openVideo(app)
    try await settleFocus(host)
    XCTAssertFalse(app.browsingPageActive)
    XCTAssertFalse(PlaybackKeyboardInput.blocksShortcut(window.firstResponder), "playback must not inherit the toolbar search editor")

    app.searchFocusRequest += 1
    try await settleFocus(host)
    XCTAssertFalse(PlaybackKeyboardInput.blocksShortcut(window.firstResponder), "a stale request must not refocus search during playback")

    app.goBack()
    try await settleFocus(host)
    XCTAssertTrue(app.browsingPageActive)
    app.searchFocusRequest += 1
    try await settleFocus(host)
    XCTAssertTrue(PlaybackKeyboardInput.blocksShortcut(window.firstResponder), "explicit search must still focus after returning")
  }

  func testBackAndForwardWalkTheOverlayStack() {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.userSpace(1))
    app.openOverlay(.search("山野"))
    XCTAssertEqual(app.overlays, [.userSpace(1), .search("山野")])
    app.goBack()
    XCTAssertEqual(app.currentOverlay, .userSpace(1))
    XCTAssertTrue(app.canGoForward)
    app.goForward()
    XCTAssertEqual(app.currentOverlay, .search("山野"))
    XCTAssertFalse(app.canGoForward)
  }

  func testOpeningSomethingNewDropsTheForwardHistory() {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.userSpace(1))
    app.openOverlay(.userSpace(2))
    app.goBack()
    XCTAssertTrue(app.canGoForward)
    app.openOverlay(.history)
    XCTAssertFalse(app.canGoForward, "a new destination ends the forward history")
    XCTAssertEqual(app.overlays, [.userSpace(1), .history])
  }

  func testSpaceFromPlaybackWithoutPlaybackIsAPlainOpen() {
    let app = model()
    defer { app.shutdown() }
    app.openSpaceKeepingPlayback(42)
    XCTAssertEqual(app.currentOverlay, .userSpace(42))
    XCTAssertFalse(app.compactPlayer, "nothing was playing, so no mini window")
    app.openSpaceKeepingPlayback(0)
    XCTAssertEqual(app.overlays.count, 1, "an unknown user opens nothing")
  }

  func testVideoBackRetainsSpaceAndDoesNotRefreshOrRepeatRegionalSearch() async {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.userSpace(42))
    app.submitRegionalSearch("山野")
    let request = app.regionalSearchRequest?.revision
    let source = app.browsingPage
    let refresh = app.refreshToken
    await openVideo(app)
    let player = app.player
    player.set("pause", "yes")
    XCTAssertEqual(app.browsingPage, source)
    XCTAssertFalse(app.browsingPageActive)
    app.goBack()
    await settle()
    XCTAssertEqual(app.currentOverlay, .userSpace(42))
    XCTAssertEqual(app.browsingPage, source)
    XCTAssertTrue(app.browsingPageActive)
    XCTAssertEqual(app.refreshToken, refresh)
    XCTAssertEqual(app.regionalSearchRequest?.revision, request)
    XCTAssertTrue(app.hasPlayback)
    XCTAssertTrue(app.pausedBrowsing.isBrowsing)
    XCTAssertTrue(app.player === player)
    XCTAssertTrue(app.canGoForward)
    app.goForward()
    await settle()
    XCTAssertEqual(app.currentOverlay, .video(video.id))
    XCTAssertTrue(app.mainShowsPlayer)
    XCTAssertFalse(app.pausedBrowsing.isBrowsing)
    XCTAssertTrue(app.player === player)
    XCTAssertTrue(app.player.paused)
    XCTAssertFalse(app.canGoForward)
    XCTAssertEqual(app.refreshToken, refresh)
  }

  func testEveryBrowsingDestinationRetainsItsIdentityAcrossVideoBack() async {
    let app = model()
    defer { app.shutdown() }
    let routes: [AppModel.OverlayRoute] = [.search("山野"), .favorites, .viewLater, .history,
      .userSpace(42), .following(42), .followers(42), .article(42)]
    let pages: [AppModel.BrowsingPage] = AppModel.Page.allCases.map { .root($0) }
      + routes.map { .overlay($0, depth: 1) }
    for source in pages {
      switch source {
      case .root(let page): app.page = page; app.overlays = []
      case .overlay(let route, _): app.overlays = [route]
      }
      let refresh = app.refreshToken
      await openVideo(app)
      XCTAssertEqual(app.browsingPage, source)
      app.goBack()
      await settle()
      XCTAssertEqual(app.browsingPage, source)
      XCTAssertTrue(app.browsingPageActive)
      XCTAssertEqual(app.refreshToken, refresh)
    }
  }

  func testPGCAndLiveBackRetainTheirSourceWithoutRefreshing() async {
    let app = model()
    defer { app.shutdown() }
    for route in [AppModel.OverlayRoute.pgc(PGCSelection(seasonID: 1)), .live(1)] {
      for mode in [MacOpenMode.mainWindow, .compact, .detached] {
        app.overlays = [.search("播放来源")]
        let source = app.browsingPage
        let refresh = app.refreshToken
        if case .pgc(let selection) = route { app.openPGC(selection) }
        else { app.openLive(1) }
        await settle()
        if mode == .compact { app.toggleCompactPlayer() }
        else if mode == .detached { app.togglePlaybackWindow() }
        if mode == .detached {
          XCTAssertEqual(app.currentOverlay, .search("播放来源"))
          XCTAssertTrue(app.browsingPageActive)
        } else {
          XCTAssertEqual(app.currentOverlay, route)
          XCTAssertEqual(app.browsingPage, source)
          XCTAssertFalse(app.browsingPageActive)
        }
        app.goBack()
        await settle()
        let backedSource = app.browsingPage
        XCTAssertEqual(app.currentOverlay, mode == .detached ? nil : .search("播放来源"))
        XCTAssertEqual(app.browsingPage, backedSource)
        XCTAssertTrue(app.browsingPageActive)
        let backRefresh = app.refreshToken
        XCTAssertEqual(backRefresh, refresh + (mode == .detached ? 1 : 0))
        if mode == .compact {
          closeExternalPicture(app, mode: mode)
          XCTAssertEqual(app.currentOverlay, route)
          XCTAssertEqual(app.browsingPage, backedSource)
          XCTAssertFalse(app.browsingPageActive)
          app.goBack()
          await settle()
          XCTAssertTrue(app.browsingPageActive)
          XCTAssertEqual(app.refreshToken, backRefresh)
        } else if mode == .detached {
          closeExternalPicture(app, mode: mode)
          await settle()
          XCTAssertFalse(app.hasPlayback)
          XCTAssertNil(app.currentOverlay)
          XCTAssertEqual(app.browsingPage, backedSource)
          XCTAssertTrue(app.browsingPageActive)
          XCTAssertEqual(app.refreshToken, backRefresh)
        }
        XCTAssertFalse(app.hasPlayback)
      }
    }
  }

  func testExternalOpenBackAndWindowCloseKeepTheSource() async {
    let app = model()
    defer { app.shutdown() }
    for mode in [MacOpenMode.compact, .detached] {
      app.overlays = [.userSpace(42)]
      let source = app.browsingPage
      let refresh = app.refreshToken
      await openVideo(app, mode: mode)
      XCTAssertEqual(app.mainShowsPlayer && app.playbackElsewhere, mode == .compact)
      XCTAssertEqual(app.browsingPageActive, mode == .detached, "detached playback leaves the source interactive")
      XCTAssertEqual(app.browsingPage, source)
      app.goBack()
      await settle()
      XCTAssertTrue(app.browsingBesidePlayback && app.hasPlayback)
      XCTAssertTrue(app.browsingPageActive)
      XCTAssertEqual(app.currentOverlay, mode == .compact ? .userSpace(42) : nil)
      let backRefresh = app.refreshToken
      XCTAssertEqual(backRefresh, refresh + (mode == .detached ? 1 : 0))
      let backedSource = app.browsingPage
      if mode == .compact {
        closeExternalPicture(app, mode: mode)
        XCTAssertTrue(app.mainShowsPlayer && !app.playbackElsewhere)
        XCTAssertEqual(app.browsingPage, backedSource)
        XCTAssertFalse(app.browsingPageActive)
        app.goBack()
        await settle()
        XCTAssertTrue(app.hasPlayback)
        XCTAssertTrue(app.pausedBrowsing.isBrowsing)
        XCTAssertTrue(app.canGoForward)
        XCTAssertEqual(app.currentOverlay, .userSpace(42))
        XCTAssertEqual(app.browsingPage, backedSource)
        XCTAssertEqual(app.refreshToken, backRefresh)
      } else {
        // Closing the standalone window ends playback; the main window stays on its list.
        closeExternalPicture(app, mode: mode)
        await settle()
        XCTAssertFalse(app.hasPlayback)
        XCTAssertNil(app.currentOverlay)
        XCTAssertTrue(app.browsingPageActive)
        XCTAssertEqual(app.browsingPage, backedSource)
        XCTAssertEqual(app.refreshToken, backRefresh)
      }
    }
  }

  func testClosingExternalWindowFromPlaceholderAndStoppingKeepTheSource() async {
    let app = model()
    defer { app.shutdown() }
    for mode in [MacOpenMode.compact, .detached] {
      for stop in [false, true] {
        app.overlays = [.favorites]
        let source = app.browsingPage
        let refresh = app.refreshToken
        await openVideo(app, mode: mode)
        if mode == .detached {
          app.closeDetachedPlayback()
        } else if stop {
          app.closePlayer()
        } else {
          closeExternalPicture(app, mode: mode)
          app.goBack()
        }
        await settle()
        XCTAssertEqual(app.browsingPage, source)
        XCTAssertTrue(app.browsingPageActive)
        XCTAssertEqual(app.hasPlayback, mode == .compact && !stop)
        XCTAssertEqual(app.canGoForward, mode == .compact && !stop)
        XCTAssertEqual(app.refreshToken, refresh)
      }
    }
  }

  func testSpaceKeepingPlaybackSurvivesRestoringThePlayerRoute() async {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.history)
    await openVideo(app)
    app.openSpaceKeepingPlayback(42)
    XCTAssertTrue(app.compactPlayer && app.browsingBesidePlayback)
    XCTAssertTrue(app.browsingPageActive)
    let source = app.browsingPage
    let refresh = app.refreshToken
    app.closeMiniPlayer(activateMain: false)
    XCTAssertEqual(app.overlays, [.history, .userSpace(42), .video(video.id)])
    XCTAssertEqual(app.browsingPage, source)
    XCTAssertFalse(app.browsingPageActive)
    app.goBack()
    await settle()
    XCTAssertEqual(app.currentOverlay, .userSpace(42))
    XCTAssertEqual(app.browsingPage, source)
    XCTAssertEqual(app.refreshToken, refresh)
    XCTAssertTrue(app.hasPlayback)
    XCTAssertTrue(app.pausedBrowsing.isBrowsing)
    XCTAssertTrue(app.canGoForward)
  }

  func testPausedBrowsingBackForwardAndReplacementDoNotRetainAPlayerAsTheSource() async {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.history)
    let origin = app.browsingPage
    await openVideo(app)
    let player = app.player
    app.openOverlay(.userSpace(42))
    let space = app.browsingPage
    XCTAssertEqual(space, .overlay(.userSpace(42), depth: 2))
    XCTAssertTrue(app.pausedBrowsing.isBrowsing && app.player.paused)
    XCTAssertTrue(app.browsingPageActive)
    app.goBack()
    await settle()
    XCTAssertTrue(app.mainShowsPlayer)
    XCTAssertEqual(app.browsingPage, origin)
    XCTAssertTrue(app.player === player)
    XCTAssertFalse(app.browsingPageActive)
    app.goForward()
    await settle()
    XCTAssertTrue(app.pausedBrowsing.isBrowsing && app.player.paused)
    XCTAssertEqual(app.browsingPage, space)
    XCTAssertTrue(app.browsingPageActive)
    let refresh = app.refreshToken
    await openVideo(app)
    XCTAssertEqual(app.overlays, [.history, .userSpace(42), .video(video.id)])
    XCTAssertEqual(app.browsingPage, space, "removing the parked player cannot shift browsing identity")
    XCTAssertEqual(app.overlays.filter(AppModel.isPlayerRoute).count, 1)
    XCTAssertFalse(app.pausedBrowsing.isBrowsing)
    app.goBack()
    await settle()
    XCTAssertEqual(app.browsingPage, space)
    XCTAssertTrue(app.browsingPageActive)
    XCTAssertEqual(app.refreshToken, refresh)
  }

  func testPausedBrowsingWindowMigrationAndFullscreenTruncationUseOnlyBrowsingDepth() async {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.history)
    let origin = app.browsingPage
    await openVideo(app)
    app.openOverlay(.userSpace(42))
    app.openOverlay(.following(42))
    let latest = app.browsingPage
    XCTAssertEqual(latest, .overlay(.following(42), depth: 3))
    app.setWindowFullScreen(true, detached: false)
    app.setWindowFullScreen(false, detached: false)
    XCTAssertEqual(app.browsingPage, latest)
    XCTAssertTrue(app.pausedBrowsing.isBrowsing)
    app.togglePlayerFullScreen()
    XCTAssertEqual(app.overlays, [.history, .video(video.id)])
    XCTAssertEqual(app.browsingPage, origin)
    XCTAssertFalse(app.browsingPageActive)
    app.openOverlay(.userSpace(42))
    let space = app.browsingPage
    app.toggleCompactPlayer()
    XCTAssertTrue(app.compactPlayer && !app.pausedBrowsing.isBrowsing)
    XCTAssertEqual(app.browsingPage, space)
    app.closeMiniPlayer(activateMain: false)
    XCTAssertEqual(app.overlays, [.history, .userSpace(42), .video(video.id)])
    XCTAssertEqual(app.browsingPage, space)
    let refresh = app.refreshToken
    app.goBack()
    await settle()
    XCTAssertTrue(app.browsingPageActive)
    XCTAssertEqual(app.browsingPage, space)
    XCTAssertEqual(app.refreshToken, refresh)
  }

  func testDirectVideoFullscreenRoundTripRetainsTheOriginalBrowsingIdentity() async {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.userSpace(42))
    let source = app.browsingPage
    let refresh = app.refreshToken
    await openVideo(app)
    app.togglePlayerFullScreen()
    app.setWindowFullScreen(true, detached: false)
    XCTAssertEqual(app.browsingPage, source)
    XCTAssertFalse(app.browsingPageActive)
    app.togglePlayerFullScreen()
    app.setWindowFullScreen(false, detached: false)
    app.goBack()
    await settle()
    XCTAssertEqual(app.currentOverlay, .userSpace(42))
    XCTAssertEqual(app.browsingPage, source)
    XCTAssertTrue(app.browsingPageActive)
    XCTAssertEqual(app.refreshToken, refresh)
  }

  func testRepeatedSpaceAtAnotherBrowsingDepthHasADifferentIdentity() {
    let app = model()
    defer { app.shutdown() }
    app.openOverlay(.userSpace(42))
    let first = app.browsingPage
    app.openOverlay(.userSpace(42))
    XCTAssertNotEqual(app.browsingPage, first)
    app.goBack()
    XCTAssertEqual(app.browsingPage, first)
  }

  func testCommandRefreshStillTargetsTheVisiblePage() async {
    let app = model()
    defer { app.shutdown() }
    await openVideo(app)
    let refresh = app.refreshToken
    let source = app.browsingPage
    await app.refresh()
    await app.debugVideoLoadRequest?.value
    XCTAssertEqual(app.refreshToken, refresh, "playback refresh must not reload its hidden source")
    XCTAssertEqual(app.browsingPage, source)
    app.openOverlay(.userSpace(42))
    let player = app.player
    await app.refresh()
    XCTAssertEqual(app.refreshToken, refresh + 1, "⌘R must still refresh visible paused browsing")
    XCTAssertTrue(app.player === player)
    app.goBack()
    await settle()
    XCTAssertEqual(app.refreshToken, refresh + 1, "returning to playback must not refresh either page")
    app.goBack()
    await settle()
    await app.refresh()
    XCTAssertEqual(app.refreshToken, refresh + 2, "⌘R must still refresh the visible root page")
  }
}
#endif
