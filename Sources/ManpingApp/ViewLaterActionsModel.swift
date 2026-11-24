import Combine
import Foundation
import ManpingCore

@MainActor final class ViewLaterActionsModel: ObservableObject {
  @Published private(set) var busyAIDs: Set<Int64> = []
  @Published private(set) var errors: [Int64: String] = [:]
  @Published private(set) var notice: String?
  private let service: BiliService
  private var task: Task<Void, Never>?
  private var observer: Task<Void, Never>?
  private var generation = UUID()

  init(service: BiliService) {
    self.service = service
    observer = Task { [weak self, service] in
      var previous: AuthIdentityEvent?
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let changed = previous.map {
          $0.epoch != event.epoch || $0.identityRevision != event.identityRevision
        } ?? false
        previous = event
        if changed {
          self.generation = UUID(); self.task?.cancel(); self.task = nil
          self.busyAIDs = []; self.errors = [:]; self.notice = nil
        }
      }
    }
  }
  deinit { task?.cancel(); observer?.cancel() }

  func isBusy(_ aid: Int64) -> Bool { busyAIDs.contains(aid) }
  func error(for aid: Int64) -> String? { errors[aid] }
  func add(_ aid: Int64, requiresLogin: @escaping () -> Void) async {
    guard aid > 0, !busyAIDs.contains(aid) else { return }
    let revision = generation
    busyAIDs.insert(aid); errors[aid] = nil; notice = nil
    let task = Task { @MainActor [weak self, service] in
      guard let self else { return }
      do {
        let initial = await service.authSnapshot()
        let expected = try await service.authorizeAppInteraction(expectedIdentity: initial)
        try await service.addViewLater(aid: aid, expectedIdentity: expected)
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard self.generation == revision, self.sameIdentity(expected, current) else { return }
        self.notice = "已加入稍后再看"
      } catch {
        guard self.generation == revision else { return }
        if let value = error as? AuthFailure, case .needsLogin = value { requiresLogin() }
        else if !(error is CancellationError) { self.errors[aid] = error.localizedDescription }
      }
      guard self.generation == revision else { return }
      self.busyAIDs.remove(aid); self.task = nil
    }
    self.task = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func sameIdentity(_ a: AuthSnapshot, _ b: AuthSnapshot) -> Bool {
    a.epoch == b.epoch && a.identityRevision == b.identityRevision && a.token?.mid == b.token?.mid
  }
}
