import ManpingCore
import Foundation

/// Writes the watch position to the account's history like the original client: every 30 s
/// while playing, and once more when the video is switched or closed. Paused players and
/// position zero are not reported; nothing is sent while signed out or when the user turned
/// the setting off. Debug playback reports never write to the account.
@MainActor final class WatchProgressReporter {
  struct Item: Equatable {
    let aid: Int64
    let cid: Int64
    var episode: Int64?
    var season: Int64?
    /// Metadata for bili-history. Empty for PGC episodes, which have no bvid.
    var bvid: String = ""
    var title: String = ""
    var author: String = ""
    var authorID: Int64 = 0
    var cover: String = ""
    var duration: Int = 0
  }

  private let service: BiliService
  private let enabled: () -> Bool
  private let onReport: @MainActor (Item, Int, UUID) -> Void
  private var sessionID = UUID()
  private weak var player: PlayerModel?
  private var item: Item?
  private var identity: AuthSnapshot?
  private var timer: Timer?
  private var lastSent: (item: Item, seconds: Int)?
  private var inFlight: (item: Item, seconds: Int)?

  init(service: BiliService, enabled: @escaping () -> Bool,
    onReport: @escaping @MainActor (Item, Int, UUID) -> Void = { _, _, _ in }) {
    self.service = service; self.enabled = enabled; self.onReport = onReport
  }

  /// Starts reporting for the media now loaded in `player`, closing out the previous one.
  func begin(_ next: Item, player: PlayerModel, identity: AuthSnapshot?) {
    if item != next { flush(); lastSent = nil }
    item = next; self.player = player; self.identity = identity; sessionID = UUID()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.send(requirePlaying: true) }
    }
  }

  /// Reports the final position (paused or not) and stops.
  func flush() {
    send(requirePlaying: false)
    timer?.invalidate(); timer = nil
    item = nil; player = nil; identity = nil
  }

  /// Identity changes revoke the old session without flushing it to another account.
  func discard() {
    timer?.invalidate(); timer = nil
    item = nil; player = nil; identity = nil; lastSent = nil
  }

  func identityChanged(to snapshot: AuthSnapshot) {
    guard let identity, identity.epoch != snapshot.epoch || identity.identityRevision != snapshot.identityRevision else { return }
    discard()
  }

  private func send(requirePlaying: Bool) {
    guard let item, let player else { return }
    let position = player.time
    guard position.isFinite, position >= 1, !requirePlaying || !player.paused else { return }
    let seconds = Int(position)
    if let lastSent, lastSent.item == item, lastSent.seconds == seconds { return }
    if let inFlight, inFlight.item == item, inFlight.seconds == seconds { return }

    // bili-history is independent of Bilibili sign-in and of the account-history toggle.
    onReport(item, seconds, sessionID)

    guard let identity, identity.state != .needsLogin, enabled() else {
      lastSent = (item, seconds)
      return
    }
    let service = self.service
    let episode = item.episode.flatMap { id in item.season.map { (id: id, season: $0) } }
    inFlight = (item, seconds)
    Task {
      do {
        // Bound to the identity checked for sign-in: a report that is late for an account switch
        // is dropped instead of being written to the new account.
        try await service.reportProgress(aid: item.aid, cid: item.cid, seconds: seconds, episode: episode, expectedIdentity: identity)
        if self.item == item { self.lastSent = (item, seconds) }
      } catch {
        // Keep the position retryable; a later tick or flush sends the same seconds again.
      }
      if self.inFlight?.item == item, self.inFlight?.seconds == seconds { self.inFlight = nil }
    }
  }
}
