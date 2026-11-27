import ManpingCore
import SwiftUI

/// Draft proxy settings for the settings page. Nothing changes until「应用并测试」, so typing a
/// host does not restart the tunnel on every keystroke (a lesson from the TV project).
@MainActor final class ProxySettingsModel: ObservableObject {
  @Published var kind = ProxyKind.none
  @Published var host = ""
  @Published var port = ""
  @Published var username = ""
  @Published var password = ""
  @Published var cipher = ShadowsocksTunnel.Cipher.chacha20
  @Published var region = RegionRoute.auto
  @Published var media = MediaRoute.onStall
  @Published private(set) var busy = false
  /// Exit check through the proxy, and the direct exit for comparison (nil until a test finishes).
  @Published private(set) var proxied: ProxyProbeResult?
  @Published private(set) var direct: ProxyProbeResult?
  /// A plain note shown instead of the exit cards, e.g. after turning the proxy off.
  @Published private(set) var notice: String?
  @Published private(set) var failure: String?
  @Published private(set) var status = "未配置"
  /// Applies settings and a password (nil keeps the stored one). `persistSecret` separates
  /// "start the tunnel for a test" from "save the password", so a failed test can roll back while
  /// the old password is still in the store. Returns an error message.
  var apply: ((ProxySettings, String?, Bool) async -> String?)?
  var test: (() async -> (proxied: Result<ProxyProbeResult, Error>, direct: ProxyProbeResult?))?
  private var storedSecret = false

  func load(_ settings: ProxySettings, hasSecret: Bool, status: String) {
    kind = settings.kind; host = settings.host; port = settings.port > 0 ? String(settings.port) : ""
    username = settings.username; cipher = settings.cipher; region = settings.region; media = settings.media
    storedSecret = hasSecret; password = ""
    self.status = status
  }
  /// Colour class of the header pill: running fine, not configured, or something to look at.
  enum StatusTone { case normal, idle, warning }
  var statusTone: StatusTone {
    switch status {
    case "隧道正常", "已启用": .normal
    case "未配置": .idle
    default: .warning
    }
  }
  func setStatus(_ value: String) { if status != value { status = value } }
  func secretStored() { storedSecret = true }

  var draft: ProxySettings {
    var value = ProxySettings()
    value.kind = kind; value.host = host.trimmingCharacters(in: .whitespaces); value.port = Int(port) ?? 0
    value.username = username.trimmingCharacters(in: .whitespaces); value.cipher = cipher
    value.region = region; value.media = media
    return value
  }
  var validation: String? {
    guard kind != .none else { return nil }
    if !ProxySettings.validHost(draft.host) { return "请填写服务器地址（只填主机名或 IP，不带协议和路径）。" }
    if !(1...65535).contains(draft.port) { return "端口应在 1–65535 之间。" }
    if kind == .shadowsocks && password.isEmpty && !storedSecret { return "请填写 Shadowsocks 密码。" }
    return nil
  }
  var passwordPlaceholder: String { storedSecret ? "已保存（留空则不修改）" : "密码" }

  func applyAndTest() {
    guard validation == nil, let apply else { return }
    busy = true; proxied = nil; direct = nil; notice = nil; failure = nil
    let draft = self.draft
    let secret = password.isEmpty ? nil : password
    // 回滚需要操作前的完整快照；新密码先不落盘，失败时本机仍是旧密码。
    let previous = ProxySettings.load(from: PerformanceEnvironment.defaults)
    let previousHadSecret = storedSecret
    Task {
      if let error = await apply(draft, secret, false) {
        failure = error; busy = false; return
      }
      if secret != nil { storedSecret = true; password = "" }
      guard draft.kind != .none, let test else { notice = "已关闭代理。"; busy = false; return }
      let outcome = await test()
      switch outcome.proxied {
      case .success(let exit):
        proxied = exit; direct = outcome.direct
        if let secret, let error = await apply(draft, secret, true) {
          failure = "代理已生效，但密码未能保存：\(error)"
          FeedbackCenter.shared.failure("代理已生效，但密码未能保存。")
        } else {
          FeedbackCenter.shared.success("代理已生效。")
        }
      case .failure(let error):
        // 测试不通过：恢复原来的设置。secret 传 nil 会复用仍留在本机的旧密码。
        let rollback = await apply(previous, nil, false)
        self.load(previous, hasSecret: previousHadSecret,
          status: previous.kind == .none ? "未配置" : "已恢复原设置")
        let reason = error.localizedDescription
        let sentence = reason.hasSuffix("。") || reason.hasSuffix(".") ? reason : reason + "。"
        let recovery = rollback == nil ? "已恢复原来的设置。" : "恢复原设置时出错：\(rollback!)"
        failure = "代理连接失败：\(sentence)" + recovery
      }
      busy = false
    }
  }
}

struct ProxySettingsCard: View {
  @ObservedObject var model: ProxySettingsModel
  @Environment(\.colorScheme) private var scheme

  private static let labelWidth: CGFloat = 96
  private static let kindOptions: [(ProxyKind, String)] = [
    (.none, "不使用"), (.http, "HTTP"), (.socks5, "SOCKS5"), (.shadowsocks, "Shadowsocks"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("代理")
          Text(Self.summary).font(Theme.Font.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        statusPill
      }
      form
    }.padding(.vertical, 4)
  }
  private static let summary = "在海外观看大陆版权内容；网络较差时也可经代理加速视频。"

  private var statusPill: some View {
    let color: Color = switch model.statusTone {
    case .normal: Theme.success(scheme)
    case .idle: Theme.tertiaryText(scheme)
    case .warning: Theme.warning(scheme)
    }
    return HStack(spacing: 5) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(model.status).font(Theme.Font.caption2.weight(.semibold))
    }.foregroundStyle(color).padding(.horizontal, 8).frame(height: 20)
      .background(model.statusTone == .idle ? Theme.fill(scheme) : color.opacity(0.16), in: Capsule())
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 14) {
      row("类型") {
        SegmentedTabs(options: Self.kindOptions, selection: $model.kind)
        Spacer(minLength: 0)
      }
      if model.kind != .none {
        row("服务器") {
          TextField("服务器地址", text: $model.host, prompt: Text("proxy.example.com 或 203.0.113.5")).labelsHidden().textFieldStyle(AppTextFieldStyle())
          TextField("端口", text: $model.port, prompt: Text("端口")).labelsHidden().textFieldStyle(AppTextFieldStyle()).monospacedDigit().frame(width: 92)
        }
        if model.kind == .socks5 {
          row("用户名") { TextField("用户名", text: $model.username, prompt: Text("可选")).labelsHidden().textFieldStyle(AppTextFieldStyle()) }
        }
        if model.kind == .shadowsocks || (model.kind == .socks5 && !model.username.isEmpty) {
          row("密码") {
            SecureField(model.passwordPlaceholder, text: $model.password, prompt: Text(model.passwordPlaceholder)).labelsHidden().textFieldStyle(AppTextFieldStyle())
            if model.kind == .shadowsocks {
              Menu {
                Picker("加密方式", selection: $model.cipher) { ForEach(ShadowsocksTunnel.Cipher.allCases) { Text($0.rawValue).tag($0) } }
                  .pickerStyle(.inline).labelsHidden()
              } label: { MenuLabel(title: model.cipher.rawValue) }
                .appMenuStyle().accessibilityLabel("加密方式")
            }
          }
        }
        Hairline()
        row("大陆版权内容") {
          Menu {
            Picker("区域解锁", selection: $model.region) { ForEach(RegionRoute.allCases) { Text($0.title).tag($0) } }
              .pickerStyle(.inline).labelsHidden()
          } label: { MenuLabel(title: model.region.title) }
            .appMenuStyle().accessibilityLabel("大陆版权内容")
          Spacer(minLength: 0)
        }
        row("视频加速") {
          SegmentedTabs(options: MediaRoute.allCases.map { ($0, $0.shortTitle) }, selection: $model.media)
          Spacer(minLength: 0)
        }
        Text("视频加速把经代理的节点加入多节点同时缓冲（需开启 网络 › 缓冲 ›「多节点同时缓冲」），按实测速度与直连节点分担；播放器的节点面板里也能切换。密码只加密保存在本机。")
          .font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        Button(model.kind == .none ? "应用" : "应用并测试") { model.applyAndTest() }
          .buttonStyle(AppButtonStyle(role: .primary, size: .small)).disabled(model.busy || model.validation != nil)
        if model.busy { ProgressView().controlSize(.small) }
        if let message = model.validation { InlineErrorText(message: message) }
        else if model.kind != .none {
          Text("会先应用新设置再测试；测试不通过会自动恢复原设置。").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
        }
      }
      if let notice = model.notice {
        Text(notice).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      }
      if let proxied = model.proxied { results(proxied) }
      if let failure = model.failure { InlineErrorText(message: failure) }
    }.padding(.top, 4)
  }

  /// Proxy exit and direct exit side by side; the proxy card turns green when it exits in mainland China.
  private func results(_ proxied: ProxyProbeResult) -> some View {
    HStack(alignment: .top, spacing: 10) {
      exitCard(title: "经代理出口", probe: proxied, highlighted: proxied.inMainland,
        verdict: proxied.inMainland ? "可以解锁大陆版权内容" : "不能解锁大陆版权内容")
      if let direct = model.direct {
        exitCard(title: "直连出口", probe: direct, highlighted: false,
          verdict: direct.inMainland ? "直连即可观看大陆版权内容" : "大陆版权内容受限")
      } else {
        exitCard(title: "直连出口", probe: nil, highlighted: false, verdict: "未能检测")
      }
    }
  }

  private func exitCard(title: String, probe: ProxyProbeResult?, highlighted: Bool, verdict: String) -> some View {
    let tint = highlighted ? Theme.success(scheme) : Theme.tertiaryText(scheme)
    let place = probe.map { [[$0.country, $0.province].filter { !$0.isEmpty }.joined(separator: " "), $0.isp].filter { !$0.isEmpty }.joined(separator: " · ") }
    return VStack(alignment: .leading, spacing: 4) {
      Text(probe.map { "\(title) · \($0.milliseconds) ms" } ?? title)
        .font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
      Text(place?.isEmpty == false ? place! : "—").font(Theme.Font.headline).lineLimit(1)
      Text([probe?.ip, verdict].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }.textSelection(.enabled)
      .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
      .background(highlighted ? Theme.success(scheme).opacity(0.10) : Theme.fill(scheme),
        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
        .strokeBorder(highlighted ? Theme.success(scheme).opacity(0.35) : Theme.separator(scheme), lineWidth: 0.5))
  }

  private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 12) {
      Text(title).font(Theme.Font.body).frame(width: Self.labelWidth, alignment: .leading)
      content()
    }
  }
}
