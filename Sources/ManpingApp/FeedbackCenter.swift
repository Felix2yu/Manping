import SwiftUI

/// 全局保存反馈：成功给一条自动消失的轻提示，失败停留更久并可手动关闭。
/// 设置窗口与主窗口各自挂一份 `FeedbackToastHost`，因为两者是不同的 NSWindow。
@MainActor final class FeedbackCenter: ObservableObject {
  static let shared = FeedbackCenter()

  struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isFailure: Bool
  }

  @Published private(set) var toast: Toast?
  private var dismissTask: Task<Void, Never>?

  private init() {}

  func success(_ message: String) { show(message, failure: false) }
  func failure(_ message: String) { show(message, failure: true) }

  func dismiss() {
    dismissTask?.cancel()
    toast = nil
  }

  private func show(_ message: String, failure: Bool) {
    let item = Toast(message: message, isFailure: failure)
    toast = item
    dismissTask?.cancel()
    dismissTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(failure ? 6 : 2.2))
      guard !Task.isCancelled else { return }
      if self?.toast?.id == item.id { self?.toast = nil }
    }
  }
}

/// 挂在窗口内容顶部的轻提示；不铺背景，空白区域不会拦截点击。
struct FeedbackToastHost: View {
  @ObservedObject private var center: FeedbackCenter
  @Environment(\.colorScheme) private var scheme

  @MainActor init() {
    _center = ObservedObject(wrappedValue: FeedbackCenter.shared)
  }

  var body: some View {
    VStack {
      if let toast = center.toast {
        HStack(spacing: 8) {
          Image(systemName: toast.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(toast.isFailure ? Theme.danger(scheme) : Theme.success(scheme))
          Text(toast.message)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.text(scheme))
            .lineLimit(3)
          Button { center.dismiss() } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText(scheme))
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      Spacer(minLength: 0)
    }
    .animation(.easeOut(duration: 0.18), value: center.toast)
  }
}
