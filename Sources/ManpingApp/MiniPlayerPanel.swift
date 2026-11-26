import AppKit
import ManpingCore
import SwiftUI

/// 小窗 (DesignSystem.md §12): a borderless floating panel on every Space, over full-screen apps
/// too, locked to the video's aspect ratio and snapping to the nearest screen corner. Like the
/// standalone playback window it never creates a PlayerModel or a second render surface: the
/// root swaps the playback page for a placeholder, then this panel becomes the one owner of the
/// picture. The main window keeps its size and place.
@MainActor final class MiniPlayerCoordinator: NSObject, NSWindowDelegate {
  enum Key { case togglePause, back, forward }

  private(set) var panel: MiniPlayerPanel?
  /// Placed with ⌥ held: left where it was dropped instead of snapping to a corner.
  private var free = false
  private let store: MiniPlayerPlacementStore
  private var screenObserver: NSObjectProtocol?

  static let defaultWidth: CGFloat = MiniPlayerLayout.defaultWidth
  static let widths: ClosedRange<CGFloat> = MiniPlayerLayout.widths
  /// Gap between the panel and the screen's visible frame when it snaps to a corner.
  static let margin: CGFloat = MiniPlayerLayout.margin
  static let cornerRadius: CGFloat = 16

  #if DEBUG
  /// `MANPING_UI_MINI_PLAYER=open|hover` with `--ui-fixture`: open the mini window once the
  /// fixture video page shows (`hover` also pins its controls) for screenshot checks.
  static let debugLaunch = ProcessInfo.processInfo.environment["MANPING_UI_MINI_PLAYER"].map { ["open", "hover"].contains($0) } ?? false
  static let debugHover = ProcessInfo.processInfo.environment["MANPING_UI_MINI_PLAYER"] == "hover"
  static var debugLaunched = false
  #else
  static let debugLaunch = false
  static let debugHover = false
  #endif

  override convenience init() { self.init(defaults: PerformanceEnvironment.defaults) }
  init(defaults: any PreferencesStore) {
    store = MiniPlayerPlacementStore(defaults: defaults)
    super.init()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.screensChanged() }
    }
  }
  isolated deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }

  /// Shows `content` in the panel. `aspect` is the video's width ÷ height.
  func present(content: NSView, aspect: CGFloat, onKey: @escaping (Key) -> Void) {
    let ratio = MiniPlayerLayout.aspect(aspect)
    let panel = self.panel ?? MiniPlayerPanel()
    panel.delegate = self
    panel.onKey = onKey
    panel.onMoveEnded = { [weak self] free in self?.moveEnded(free: free) }
    panel.onResizeEnded = { [weak self] in self?.finishResize() }
    panel.onResizeRequest = { [weak self] width in self?.resize(toWidth: width) }
    panel.contentView = MiniPlayerContainer(content: content, radius: Self.cornerRadius)
    self.panel = panel
    let frame = initialFrame(ratio: ratio)
    lock(panel, ratio: ratio, screen: MiniPlayerLayout.screen(for: frame).visibleFrame)
    panel.setFrame(frame, display: true)
    if !free { snap(animated: false) }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      panel.animator().alphaValue = 1
    }
    panel.invalidateShadow()
    #if DEBUG
    if Bundle.main.bundleURL.pathExtension == "app" {
      let file = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("mini-window-id")
      try? String(panel.windowNumber).write(to: file, atomically: true, encoding: .utf8)
    }
    #endif
  }

  /// Removes the picture first (so the next owner can take the render surface), then the panel.
  func close() {
    guard let panel else { return }
    save(panel.frame)
    panel.delegate = nil
    panel.onKey = nil; panel.onMoveEnded = nil; panel.onResizeEnded = nil; panel.onResizeRequest = nil
    panel.contentView = nil
    panel.orderOut(nil)
    self.panel = nil
  }

  func bringToFront() { panel?.orderFrontRegardless() }

  /// The video changed size (its stream became known, or the next item plays): the panel
  /// takes the new aspect ratio and keeps its size class and corner.
  func update(aspect: CGFloat) {
    guard let panel else { return }
    let ratio = MiniPlayerLayout.aspect(aspect)
    let current = panel.contentAspectRatio
    if current.height > 0, abs(current.width / current.height - ratio) < 0.01 { return }
    let frame = panel.frame
    let screen = MiniPlayerLayout.screen(for: frame)
    lock(panel, ratio: ratio, screen: screen.visibleFrame)
    let size = MiniPlayerLayout.size(aspect: ratio, boxWidth: MiniPlayerLayout.boxWidth(frame.size), screen: screen)
    // Keep the edge nearest the screen's corner in place, then snap as after a resize.
    let right = frame.midX >= screen.visibleFrame.midX, top = frame.midY >= screen.visibleFrame.midY
    var target = NSRect(x: right ? frame.maxX - size.width : frame.minX, y: top ? frame.maxY - size.height : frame.minY,
      width: size.width, height: size.height)
    target = MiniPlayerLayout.constrain(target, to: screen)
    panel.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    panel.invalidateShadow()
    if free { save(target) } else { snap(animated: false) }
  }

  // MARK: Sizing and placement

  private static func screens() -> [MiniPlayerLayout.Screen] {
    MiniPlayerLayout.screens(NSScreen.screens, primary: NSScreen.main)
  }

  private func initialFrame(ratio: CGFloat) -> NSRect {
    let saved = store.load()
    free = saved?.free ?? false
    let restored = MiniPlayerLayout.restoredFrame(saved: saved?.frame, aspect: ratio,
      screens: Self.screens(), preferredScreenID: saved?.screenID)
    // A frame whose display has disappeared starts on the main screen instead of retaining the
    // old free placement; an existing display keeps the user's exact (now clamped) position.
    free = free && restored.keepFreePlacement
    return restored.frame
  }

  /// Locks resizing to the video's own aspect ratio, between the smallest and largest boxes.
  private func lock(_ panel: NSPanel, ratio: CGFloat, screen: CGRect) {
    panel.contentAspectRatio = NSSize(width: ratio, height: 1)
    let bounds = MiniPlayerLayout.Screen(frame: screen, visibleFrame: screen)
    panel.contentMinSize = MiniPlayerLayout.size(aspect: ratio, boxWidth: Self.widths.lowerBound, screen: bounds)
    panel.contentMaxSize = MiniPlayerLayout.size(aspect: ratio, boxWidth: Self.widths.upperBound, screen: bounds)
  }

  private func resize(toWidth width: CGFloat) {
    guard let panel else { return }
    let ratio = MiniPlayerLayout.aspect(panel.contentAspectRatio.width / panel.contentAspectRatio.height)
    let frame = panel.frame
    let screen = MiniPlayerLayout.screen(for: frame)
    lock(panel, ratio: ratio, screen: screen.visibleFrame)
    let size = MiniPlayerLayout.size(aspect: ratio, boxWidth: width, screen: screen)
    let right = frame.midX >= screen.visibleFrame.midX, top = frame.midY >= screen.visibleFrame.midY
    var target = MiniPlayerLayout.constrain(NSRect(
      x: right ? frame.maxX - size.width : frame.minX,
      y: top ? frame.maxY - size.height : frame.minY,
      width: size.width, height: size.height), to: screen)
    if !free { target = MiniPlayerLayout.snappedFrame(target, on: screen) }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel.setFrame(target, display: true)
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(target, display: true)
      }
    }
    panel.invalidateShadow()
    save(target)
  }

  /// Moves the panel into the corner of its screen nearest to its centre, 16pt from the edges.
  private func snap(animated: Bool) {
    guard let panel else { return }
    let target = MiniPlayerLayout.snappedFrame(panel.frame, on: MiniPlayerLayout.screen(for: panel.frame))
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.setFrame(target, display: true)
    }
    save(target)
  }

  private func moveEnded(free: Bool) {
    self.free = free
    if free { if let panel { save(panel.frame) } } else { snap(animated: true) }
  }

  /// Both AppKit's native edges and the explicit bottom-right handle finish here. Persistence is
  /// unconditional after a resize: a snapped window is saved at its final corner too.
  private func finishResize() {
    guard let panel, !panel.isResizing else { return }
    reflowAfterScreenChange(animated: true)
  }

  @objc private func screensChanged() {
    guard panel?.isResizing != true else { return }
    reflowAfterScreenChange(animated: false)
  }

  func windowDidChangeScreen(_ notification: Notification) { screensChanged() }

  /// Fits and repositions on the screen with the largest remaining overlap. This also covers
  /// unplugging the saved display, changing its resolution, or moving the Dock/menu bar.
  private func reflowAfterScreenChange(animated: Bool) {
    guard let panel, !NSScreen.screens.isEmpty else { return }
    let ratio = MiniPlayerLayout.aspect(panel.contentAspectRatio.width / panel.contentAspectRatio.height)
    let screen = MiniPlayerLayout.screen(for: panel.frame)
    lock(panel, ratio: ratio, screen: screen.visibleFrame)
    var target = MiniPlayerLayout.constrain(panel.frame, to: screen)
    if !free { target = MiniPlayerLayout.snappedFrame(target, on: screen) }
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.setFrame(target, display: true)
    }
    panel.invalidateShadow()
    save(target)
  }

  private func save(_ frame: NSRect) {
    let screen = MiniPlayerLayout.screen(for: frame, preferredScreenID: panel?.screen.map(MiniPlayerLayout.screenID))
    store.save(frame: frame, free: free, screenID: screen.id)
  }

  func windowDidEndLiveResize(_ notification: Notification) { finishResize() }
  func windowDidResize(_ notification: Notification) { panel?.invalidateShadow() }
}

/// Pure geometry shared by the coordinator and the resize hit view. Keeping screen selection here
/// makes disconnected-display recovery testable without creating a window or querying real screens.
enum MiniPlayerLayout {
  struct Screen: Equatable {
    var id: String?
    var frame: CGRect
    var visibleFrame: CGRect
    var isPrimary: Bool = false
  }

  enum Preset: CaseIterable {
    case small, medium, large
    var width: CGFloat { switch self { case .small: 360; case .medium: 480; case .large: 720 } }
    var title: String { switch self { case .small: "小"; case .medium: "中"; case .large: "大" } }
    var accessibilityLabel: String { switch self { case .small: "小尺寸"; case .medium: "中尺寸"; case .large: "大尺寸" } }
  }

  static let defaultWidth: CGFloat = 480
  static let widths: ClosedRange<CGFloat> = 320...960
  static let margin: CGFloat = 16
  static let resizeHitSize: CGFloat = 34
  static let resizeGlyphSize: CGFloat = 24

  static func aspect(_ value: CGFloat) -> CGFloat {
    value.isFinite && value > 0 ? value : CGFloat(MiniWindowSizing.fallbackAspect)
  }

  static func screens(_ native: [NSScreen], primary: NSScreen?) -> [Screen] {
    let primaryID = primary.map(screenID)
    return native.map {
      Screen(id: screenID($0), frame: $0.frame, visibleFrame: $0.visibleFrame, isPrimary: screenID($0) == primaryID)
    }
  }

  static func screenID(_ screen: NSScreen) -> String {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
      ?? screen.deviceDescription[NSDeviceDescriptionKey("NSScreenUUID")] as? String ?? ObjectIdentifier(screen).hashValue.description
  }

  static func screen(for frame: CGRect, in screens: [MiniPlayerLayout.Screen]? = nil,
    preferredScreenID: String? = nil) -> Screen {
    let screens = screens ?? MiniPlayerLayout.screens(NSScreen.screens, primary: NSScreen.main)
    let usable = screens.filter { valid($0.frame) && valid($0.visibleFrame) }
    if let id = preferredScreenID, let match = usable.first(where: { $0.id == id }) { return match }
    if let best = usable.map({ (screen: $0, area: intersectionArea(frame, $0.visibleFrame)) })
      .filter({ $0.area > 0 }).max(by: { $0.area < $1.area })?.screen { return best }
    return usable.first(where: \.isPrimary) ?? usable.first ?? Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), isPrimary: true)
  }

  /// Size for a video inside a square/2.4:1 shaping box, fitted entirely inside the usable area.
  /// Only the width is floored; deriving height from it keeps the video ratio exact while ensuring
  /// the content constraints never exceed the screen.
  static func size(aspect: CGFloat, boxWidth: CGFloat, screen: Screen) -> CGSize {
    let ratio = aspect.isFinite && aspect > 0 ? aspect : CGFloat(MiniWindowSizing.fallbackAspect)
    let box = min(widths.upperBound, max(widths.lowerBound, boxWidth.isFinite ? boxWidth : defaultWidth))
    let boxRatio = min(Double(MiniWindowSizing.boxRatios.upperBound), max(Double(MiniWindowSizing.boxRatios.lowerBound), Double(ratio)))
    let boxHeight = Double(box) / boxRatio
    var width = Double(ratio) >= boxRatio ? Double(box) : boxHeight * Double(ratio)
    var height = width / Double(ratio)
    let usable = usableFrame(screen.visibleFrame)
    let scale = min(1, usable.width / width, usable.height / height)
    if scale.isFinite, scale > 0 { width *= scale; height *= scale }
    width = min(usable.width, max(1, width.rounded(.down)))
    height = width / Double(ratio)
    if height > usable.height { height = usable.height; width = height * Double(ratio) }
    return CGSize(width: max(1, width), height: max(1, height))
  }

  static func boxWidth(_ size: CGSize) -> CGFloat {
    guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return defaultWidth }
    let ratio = min(Double(MiniWindowSizing.boxRatios.upperBound),
      max(Double(MiniWindowSizing.boxRatios.lowerBound), Double(size.width / size.height)))
    return CGFloat(max(Double(size.width), Double(size.height) * ratio))
  }

  /// Clamp both dimensions and origin, including frames restored partly or wholly off-screen.
  static func constrain(_ frame: CGRect, to screen: Screen) -> CGRect {
    let visible = screen.visibleFrame
    guard valid(frame), valid(visible) else { return frame }
    let size = size(aspect: frame.width / frame.height, boxWidth: boxWidth(frame.size), screen: screen)
    let origin = clampedOrigin(frame.origin, size: size, in: usableFrame(visible))
    return CGRect(origin: origin, size: size)
  }

  static func snappedFrame(_ frame: CGRect, on screen: Screen) -> CGRect {
    let visible = screen.visibleFrame
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let usable = usableFrame(visible)
    return constrain(CGRect(x: center.x < visible.midX ? usable.minX : usable.maxX - frame.width,
      y: center.y < visible.midY ? usable.minY : usable.maxY - frame.height,
      width: frame.width, height: frame.height), to: screen)
  }

  /// Result of opening with a saved frame. A missing display deliberately falls back to the main
  /// screen's bottom-right corner; a connected display retains the free/snapped placement choice.
  static func restoredFrame(saved: CGRect?, aspect: CGFloat, screens: [Screen], preferredScreenID: String?) ->
    (frame: CGRect, screen: Screen, keepFreePlacement: Bool) {
    let screen = screen(for: saved ?? .zero, in: screens, preferredScreenID: preferredScreenID)
    if let saved, valid(saved), saved.width > 0, saved.height > 0 {
      let knownScreen = screens.contains { $0.id == preferredScreenID && $0.id != nil }
        || screens.contains { intersectionArea(saved, $0.visibleFrame) > 0 }
      if knownScreen {
        return (constrain(saved, to: screen), screen, true)
      }
    }
    let size = size(aspect: aspect, boxWidth: saved.flatMap { valid($0) && $0.width > 0 ? boxWidth($0.size) : nil } ?? defaultWidth,
      screen: screen)
    let visible = usableFrame(screen.visibleFrame)
    return (CGRect(x: visible.maxX - size.width, y: visible.minY, width: size.width, height: size.height), screen, false)
  }

  /// Project a bottom-right drag onto the video ratio. The axis with the larger relative movement
  /// drives the scale, so diagonal drags stay predictable while the opposite corner remains fixed.
  static func resizedSize(start: CGSize, proposed: CGSize, aspect: CGFloat, screen: Screen) -> CGSize {
    guard start.width > 0, start.height > 0 else { return size(aspect: aspect, boxWidth: defaultWidth, screen: screen) }
    let ratio = aspect.isFinite && aspect > 0 ? aspect : CGFloat(MiniWindowSizing.fallbackAspect)
    let horizontal = abs(proposed.width - start.width) / start.width
    let vertical = abs(proposed.height - start.height) / start.height
    let scale = max(0.01, horizontal >= vertical ? proposed.width / start.width : proposed.height / start.height)
    var width = start.width * scale
    let usable = usableFrame(screen.visibleFrame)
    width = min(widths.upperBound, max(widths.lowerBound, width), usable.width)
    var height = width / ratio
    if height > usable.height { height = usable.height; width = height * ratio }
    return CGSize(width: max(1, width), height: max(1, height))
  }

  static func valid(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
  }

  private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    guard valid(a), valid(b), a.intersects(b) else { return 0 }
    let intersection = a.intersection(b)
    return max(0, intersection.width) * max(0, intersection.height)
  }

  private static func usableFrame(_ visible: CGRect) -> CGRect {
    guard visible.width > 2 * margin, visible.height > 2 * margin else { return visible }
    return visible.insetBy(dx: margin, dy: margin)
  }

  private static func clampedOrigin(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
    CGPoint(x: min(max(origin.x, visible.minX), visible.maxX - size.width),
      y: min(max(origin.y, visible.minY), visible.maxY - size.height))
  }
}

/// Backwards-compatible frame keys plus a display identity, so a reconnect can recover the right
/// screen while an unplugged display falls back cleanly. Malformed legacy frames are ignored.
struct MiniPlayerPlacementStore {
  struct Saved: Equatable { var frame: CGRect; var free: Bool; var screenID: String? }
  private let defaults: any PreferencesStore
  private static let frameKey = "Manping.miniPlayerFrame"
  private static let freeKey = "Manping.miniPlayerFree"
  private static let screenKey = "Manping.miniPlayerScreen"

  init(defaults: any PreferencesStore) { self.defaults = defaults }

  func load() -> Saved? {
    guard let serialized = defaults.string(forKey: Self.frameKey) else { return nil }
    let frame = NSRectFromString(serialized)
    guard MiniPlayerLayout.valid(frame), frame.width > 0, frame.height > 0 else { return nil }
    return Saved(frame: frame, free: defaults.bool(forKey: Self.freeKey), screenID: defaults.string(forKey: Self.screenKey))
  }

  func save(frame: CGRect, free: Bool, screenID: String?) {
    guard MiniPlayerLayout.valid(frame) else { return }
    defaults.set(NSStringFromRect(frame), forKey: Self.frameKey)
    defaults.set(free, forKey: Self.freeKey)
    if let screenID { defaults.set(screenID, forKey: Self.screenKey) } else { defaults.removeObject(forKey: Self.screenKey) }
  }
}

/// The panel itself: no title bar, floating, on every Space and beside full-screen apps, never
/// in the Dock or ⌘Tab. Clicking it does not activate the app, so it can sit over other work.
final class MiniPlayerPanel: NSPanel, DanmakuFitting {
  var onKey: ((MiniPlayerCoordinator.Key) -> Void)?
  var onMoveEnded: ((Bool) -> Void)?
  var onResizeEnded: (() -> Void)?
  var onResizeRequest: ((CGFloat) -> Void)?
  private(set) var isResizing = false
  private var dragPoll: Timer?
  var danmakuFit: DanmakuFit { .miniPlayer }

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
      styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    title = "小窗"
    identifier = NSUserInterfaceItemIdentifier(AppIdentity.bundleIdentifier + ".mini-player")
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isRestorable = false
    isExcludedFromWindowsMenu = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovable = true
    isMovableByWindowBackground = false
    acceptsMouseMovedEvents = true
    animationBehavior = .utilityWindow
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Space and ←/→ when the menu bar does not handle them (the app is not active).
  override func keyDown(with event: NSEvent) {
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let onKey else {
      super.keyDown(with: event); return
    }
    switch event.keyCode {
    case 49: onKey(.togglePause)
    case 123: onKey(.back)
    case 124: onKey(.forward)
    default: super.keyDown(with: event)
    }
  }

  /// Moves the panel with the pointer from `event` (a mouse-down), then reports where it was
  /// dropped; ⌥ held at the drop leaves it there instead of snapping.
  func drag(from event: NSEvent) {
    performDrag(with: event)
    finishDragWhenReleased()
  }

  /// Bottom-right live resize with the opposite corner fixed. A borderless window does not get
  /// reliable native resize edges, so the visible handle owns this event loop explicitly.
  func resize(from event: NSEvent) {
    guard event.type == .leftMouseDown, !isResizing else { return }
    isResizing = true
    let start = frame
    let anchor = CGPoint(x: start.minX, y: start.maxY)
    let ratio = MiniPlayerLayout.aspect(contentAspectRatio.width / contentAspectRatio.height)
    while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if next.type == .leftMouseUp { break }
      // Window coordinates move with the frame; convert every sample back to screen coordinates.
      let pointer = convertToScreen(NSRect(origin: next.locationInWindow, size: .zero)).origin
      let pointerScreen = MiniPlayerLayout.screen(for: CGRect(origin: pointer, size: .zero))
      let proposed = CGSize(width: anchor.x - pointer.x, height: pointer.y - anchor.y)
      let size = MiniPlayerLayout.resizedSize(start: start.size, proposed: proposed, aspect: ratio, screen: pointerScreen)
      setFrame(CGRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height), display: true)
    }
    isResizing = false
    invalidateShadow()
    onResizeEnded?()
  }

  private func finishDragWhenReleased() {
    dragPoll?.invalidate()
    guard NSEvent.pressedMouseButtons & 1 != 0 else {
      onMoveEnded?(NSEvent.modifierFlags.contains(.option)); return
    }
    // The drag runs on after `performDrag` returned: wait for the button to come up.
    let poll = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        self?.dragPoll?.invalidate()
        self?.dragPoll = nil
        self?.onMoveEnded?(NSEvent.modifierFlags.contains(.option))
      }
    }
    RunLoop.main.add(poll, forMode: .common)
    dragPoll = poll
  }
}

/// Rounds the panel's corners (16pt, continuous) around the hosted SwiftUI view.
private final class MiniPlayerContainer: NSView {
  init(content: NSView, radius: CGFloat) {
    super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
    wantsLayer = true
    layer?.cornerRadius = radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.borderWidth = 0.5
    layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    content.frame = bounds
    content.autoresizingMask = [.width, .height]
    addSubview(content)
  }
  required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Content

/// The mini window's content: the picture and danmaku, and on hover a 28% dimming with
/// 「关闭小窗」「回到主窗口」, 小/中/大 presets, the danmaku switch, 「−10 · 播放 · +10」 and a thin
/// progress line. The controls fade after 1.5 s without activity. Click pauses or resumes,
/// double-click returns to the main window, dragging anywhere moves the panel, and the bottom-right
/// grip resizes it without changing the video's aspect ratio.
struct MiniPlayerContent: View {
  @ObservedObject var model: AppModel
  @State private var panel: MiniPlayerPanel?
  var body: some View {
    MiniPlayerStage(model: model, player: model.player, resize: { panel?.onResizeRequest?($0) })
      .id(ObjectIdentifier(model.player))
      .environment(\.colorScheme, .dark)
      .tint(Theme.accent)
      .background { MiniPlayerPanelReader { panel = $0 } }
  }
}

/// Bridges SwiftUI's preset buttons back to the hosting panel without changing AppModel's
/// present/toggle contract or making the panel a global singleton.
private struct MiniPlayerPanelReader: NSViewRepresentable {
  let onPanel: (MiniPlayerPanel?) -> Void
  func makeNSView(context: Context) -> MiniPlayerPanelReaderView { MiniPlayerPanelReaderView(frame: .zero) }
  func updateNSView(_ view: MiniPlayerPanelReaderView, context: Context) {
    view.onPanel = onPanel
    if view.observedWindow !== view.window {
      view.observedWindow = view.window
      view.onPanel(view.window as? MiniPlayerPanel)
    }
  }
}

private final class MiniPlayerPanelReaderView: NSView {
  var onPanel: (MiniPlayerPanel?) -> Void = { _ in }
  weak var observedWindow: NSWindow?
  override init(frame: NSRect) { super.init(frame: frame) }
  required init?(coder: NSCoder) { fatalError() }
}

private struct MiniPlayerStage: View {
  @ObservedObject var model: AppModel
  @ObservedObject var player: PlayerModel
  var resize: (CGFloat) -> Void
  @StateObject private var chrome = PlayerChromeState(idleDelay: 1.5)

  private var live: LivePlaybackModel? { model.livePlayback }
  private var showsCover: Bool { model.usesUIFixtures && !PerformanceOptions.playsLocalMedia }
  private var cover: URL? {
    if let live { return live.room?.cover }
    return model.pgcPlayback?.episode?.cover ?? model.videoDetails?.video.cover ?? model.selected?.cover
  }
  private var duration: Double {
    if player.duration > 0 { return player.duration }
    if let episode = model.pgcPlayback?.episode { return Double(episode.duration) }
    return Double(model.videoDetails?.video.duration ?? 0)
  }
  private var shown: Bool { chrome.visible || chrome.pinned || MiniPlayerCoordinator.debugHover }

  var body: some View {
    ZStack {
      Color.black
      PlayerSurface(model: player)
      if showsCover {
        // In an overlay the filled cover cannot grow the stack past the panel (which would push
        // the top buttons and the progress line out of view).
        Color.clear.overlay { CachedImage(url: cover).aspectRatio(contentMode: .fill) }
          .clipped().allowsHitTesting(false)
      } else if player.audioOnly {
        AudioOnlyBackdrop(cover: cover, title: "")
      }
      MiniPlayerMouseArea(
        hover: { inside in inside ? chrome.pointerActivity() : chrome.pointerLeft() },
        moved: { chrome.pointerActivity() },
        click: { chrome.activity(); player.togglePause() },
        doubleClick: { leave { model.toggleCompactPlayer() } })
      controls.playerChromeFade(shown)
      MiniPlayerResizeHandle(began: { chrome.activity() })
        .frame(width: MiniPlayerLayout.resizeHitSize, height: MiniPlayerLayout.resizeHitSize)
        .background { MiniPlayerResizeGlyph() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 1)
        .padding(.bottom, 1)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityLabel("调整小窗大小")
        .accessibilityHint("拖动以保持视频宽高比缩放")
      // 「N 秒后播放下一个」 with 取消, under the top buttons and clear of the centre controls;
      // it stays visible while the controls fade, since it acts on its own.
      if let deadline = model.nextPlaybackDeadline {
        MiniNextPlaybackPrompt(deadline: deadline, cancel: model.cancelNextPlayback)
          .frame(maxHeight: .infinity, alignment: .top)
          .padding(.top, shown ? 46 : 10)
          .animation(.easeOut(duration: 0.2), value: shown)
          .transition(.opacity)
      }
    }
    .animation(.snappy(duration: 0.25), value: model.nextPlaybackDeadline == nil)
    .onAppear {
      chrome.playing = !player.paused
      chrome.pinned = player.paused
      chrome.activity()
    }
    .onChange(of: player.paused) { _, paused in
      chrome.playing = !paused
      chrome.pinned = paused
      chrome.activity()
    }
    .onChange(of: player.commentsEnabled) { _, _ in chrome.activity() }
    .onDisappear { chrome.stop() }
    #if DEBUG
    .modifier(DemoMiniHooks(chrome: chrome))
    #endif
  }

  private var controls: some View {
    ZStack {
      Color.black.opacity(0.28).allowsHitTesting(false)
      VStack(spacing: 0) {
        GlassEffectContainer(spacing: 6) {
          HStack(spacing: 6) {
            Button { leave { model.closePlayer() } } label: { Image(systemName: "xmark") }
              .buttonStyle(MiniGlassButtonStyle()).help("关闭小窗").accessibilityLabel("关闭小窗")
            Button { leave { model.toggleCompactPlayer() } } label: { Image(systemName: "pip.exit") }
              .buttonStyle(MiniGlassButtonStyle()).help("回到主窗口").accessibilityLabel("回到主窗口")
            GlassEffectContainer(spacing: 4) {
              HStack(spacing: 4) {
                ForEach(MiniPlayerLayout.Preset.allCases, id: \.self) { preset in
                  Button { chrome.activity(); resize(preset.width) } label: { Text(preset.title) }
                    .buttonStyle(MiniGlassButtonStyle())
                    .help("\(preset.accessibilityLabel)小窗")
                    .accessibilityLabel(preset.accessibilityLabel)
                }
              }
            }
            if let live { LiveBadge(status: live.room?.status ?? .live).padding(.leading, 2) }
            Spacer(minLength: 0)
            Button { player.commentsEnabled.toggle() } label: {
              DanmakuSymbol().fill(.foreground).frame(width: 15, height: 15)
            }.buttonStyle(MiniGlassButtonStyle(active: player.commentsEnabled))
              .help(player.commentsEnabled ? "隐藏弹幕" : "显示弹幕").accessibilityLabel("弹幕")
              .accessibilityValue(player.commentsEnabled ? "显示" : "隐藏")
          }
        }
        Spacer(minLength: 4)
        HStack(spacing: 20) {
          if live == nil {
            Button { seek(by: -10) } label: { Image(systemName: "gobackward.10") }
              .buttonStyle(MiniGlassButtonStyle(size: 34)).help("后退 10 秒").accessibilityLabel("后退 10 秒")
          }
          PlayerPlayButton(paused: player.paused, size: 44) { player.togglePause() }
          if live == nil {
            Button { seek(by: 10) } label: { Image(systemName: "goforward.10") }
              .buttonStyle(MiniGlassButtonStyle(size: 34)).help("前进 10 秒").accessibilityLabel("前进 10 秒")
          }
        }
        Spacer(minLength: 4)
        if live == nil {
          VStack(alignment: .leading, spacing: 6) {
            PlayerTimeLabel(clock: player.clock, duration: duration)
            PlaybackProgressBar(clock: player.clock, duration: duration).clipShape(Capsule())
              .padding(.trailing, MiniPlayerLayout.resizeHitSize)
          }
        }
      }.padding(10)
        .contentShape(Rectangle())
        .onHover { chrome.setOverControls($0) }
    }
  }

  /// Actions that close the panel run on the next turn: tearing down the hosting view inside
  /// its own event handling would release it mid-call.
  private func leave(_ action: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { action() }
  }

  private func seek(by seconds: Double) {
    chrome.activity()
    player.seek(min(max(0, duration), max(0, player.time + seconds)))
  }
}

/// The mini window's countdown to the next item: a glass capsule with the seconds left and
/// 取消. Only this view redraws while it counts down.
private struct MiniNextPlaybackPrompt: View {
  let deadline: Date
  let cancel: () -> Void
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { context in
      let remaining = Int(ceil(max(0, deadline.timeIntervalSince(context.date))))
      HStack(spacing: 8) {
        Text("\(remaining) 秒后播放下一个").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.white)
        Button("取消", action: cancel).buttonStyle(.plain).font(Theme.Font.caption.weight(.semibold))
          .foregroundStyle(Theme.accentText(.dark)).accessibilityLabel("取消播放下一个")
      }
      .padding(.horizontal, 12).frame(height: 28)
      .glassEffect(.regular.tint(.black.opacity(0.25)), in: Capsule())
    }
  }
}

/// Small round Liquid Glass buttons on the mini window.
private struct MiniGlassButtonStyle: ButtonStyle {
  var size: CGFloat = 28
  var active = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(active ? Theme.onAccent : .white)
      .frame(width: size, height: size)
      // On: a solid accent disc like the main panel's switch (a tinted glass washes out to grey).
      .background { if active { Circle().fill(Theme.accent) } }
      .glassEffect(active ? .regular.interactive() : .regular.tint(.black.opacity(0.2)).interactive(), in: Circle())
      .contentShape(Circle())
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
  }
}

/// A visible diagonal grip with a 34pt square hit region. It sits above the picture's drag area,
/// so a resize never turns into a window move or a double-click return to the main window.
private struct MiniPlayerResizeHandle: NSViewRepresentable {
  let began: () -> Void
  func makeNSView(context: Context) -> MiniPlayerResizeHandleView { MiniPlayerResizeHandleView() }
  func updateNSView(_ view: MiniPlayerResizeHandleView, context: Context) { view.began = began }
}

private final class MiniPlayerResizeHandleView: NSView {
  var began: () -> Void = {}
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func mouseDown(with event: NSEvent) {
    began()
    (window as? MiniPlayerPanel)?.resize(from: event)
  }
}

/// The grip shown inside the resize handle's larger hit region.
private struct MiniPlayerResizeGlyph: View {
  var body: some View {
    Image(systemName: "arrow.up.left.and.arrow.down.right")
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: MiniPlayerLayout.resizeGlyphSize, height: MiniPlayerLayout.resizeGlyphSize)
      .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: Circle())
      .contentShape(Circle())
  }
}

/// AppKit mouse handling under the mini window's controls: hover (in any app state), click,
/// double-click and dragging the panel by any point of the picture.
private struct MiniPlayerMouseArea: NSViewRepresentable {
  let hover: (Bool) -> Void
  let moved: () -> Void
  let click: () -> Void
  let doubleClick: () -> Void
  func makeNSView(context: Context) -> MiniPlayerMouseView { MiniPlayerMouseView() }
  func updateNSView(_ view: MiniPlayerMouseView, context: Context) {
    view.hover = hover; view.moved = moved; view.click = click; view.doubleClick = doubleClick
  }
}

private final class MiniPlayerMouseView: NSView {
  var hover: (Bool) -> Void = { _ in }
  var moved: () -> Void = {}
  var click: () -> Void = {}
  var doubleClick: () -> Void = {}
  private var pendingClick: DispatchWorkItem?
  private var tracking: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hover(true) }
  override func mouseExited(with event: NSEvent) { hover(false) }
  override func mouseMoved(with event: NSEvent) { moved() }

  override func mouseDown(with event: NSEvent) {
    moved()
    if event.clickCount >= 2 {
      pendingClick?.cancel(); pendingClick = nil
      doubleClick()
      return
    }
    guard let panel = window as? MiniPlayerPanel else { return }
    let start = event.locationInWindow
    // A click unless the pointer travels 3pt before the button comes up; then a window drag.
    while let next = panel.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      if next.type == .leftMouseUp {
        let work = DispatchWorkItem { [weak self] in self?.pendingClick = nil; self?.click() }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        return
      }
      let point = next.locationInWindow
      if hypot(point.x - start.x, point.y - start.y) >= 3 {
        panel.drag(from: event)
        return
      }
    }
  }
}
