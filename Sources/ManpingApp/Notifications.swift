import Foundation
import SwiftUI

extension View {
  func onMainActorNotification<Message>(
    _ type: Message.Type, perform action: @escaping @MainActor (Message) -> Void
  ) -> some View where Message: NotificationCenter.MainActorMessage, Message.Subject: AnyObject {
    modifier(MainActorNotificationModifier(messageType: type, action: action))
  }
}

private struct MainActorNotificationModifier<Message>: ViewModifier
where Message: NotificationCenter.MainActorMessage, Message.Subject: AnyObject {
  let messageType: Message.Type
  let action: @MainActor (Message) -> Void
  @State private var token: NotificationCenter.ObservationToken?

  func body(content: Content) -> some View {
    content
      .onAppear {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = NotificationCenter.default.addObserver(for: messageType) { action($0) }
      }
      .onDisappear {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
      }
  }
}