import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var windowChannel: FlutterMethodChannel?
  private var mainViewId: Int64 = 0
  private var interceptClose = false

  private func applyOpaqueWindowAppearance() {
    // 恢复系统默认的不透明窗口背景
    self.isOpaque = true
    self.backgroundColor = .windowBackgroundColor

    // 正常显示标题栏时禁用透明效果
    if self.titleVisibility == .visible {
      self.titlebarAppearsTransparent = false
      self.styleMask.remove(.fullSizeContentView)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    // 先不显示窗口
    self.isReleasedWhenClosed = false
    self.contentViewController = flutterViewController
    self.setFrame(self.frame, display: true)

    applyOpaqueWindowAppearance()

    RegisterGeneratedPlugins(registry: flutterViewController)
    windowChannel = FlutterMethodChannel(
      name: "window_control", binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel?.setMethodCallHandler { [weak self] call, result in
      self?.handleWindowCall(call, result: result)
    }
    delegate = self

    // 监听首帧渲染完成再显示窗口
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("io.flutter.embedding.engine.firstFrame"),
      object: flutterViewController.engine, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.applyOpaqueWindowAppearance()
      self.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    // 不在这里调用 makeKeyAndOrderFront
    super.awakeFromNib()
  }

  private var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

  private func windowState() -> [String: Any] {
    return [
      "viewId": mainViewId,
      "bounds": [frame.minX, desktopTop - frame.maxY, frame.width, frame.height],
      "maximized": isZoomed,
      "minimized": isMiniaturized,
      "visible": isVisible,
    ]
  }

  private func setTitleBar(_ show: Bool) {
    titleVisibility = show ? .visible : .hidden
    titlebarAppearsTransparent = !show
    isMovableByWindowBackground = !show
    if show {
      styleMask.remove(.fullSizeContentView)
    } else {
      styleMask.insert(.fullSizeContentView)
    }
  }

  private func configure(_ args: [String: Any]) {
    interceptClose = args["interceptClose"] as? Bool ?? false
    title = args["title"] as? String ?? title
    setTitleBar(args["showTitleBar"] as? Bool ?? true)
    level = args["alwaysOnTop"] as? Bool == true ? .floating : .normal
    if let size = args["minimumSize"] as? [Double], size.count == 2 {
      minSize = NSSize(width: size[0], height: size[1])
    }
    if let size = args["size"] as? [Double], size.count == 2 {
      let width = size[0], height = size[1]
      if let position = args["position"] as? [Double], position.count >= 2,
        NSScreen.screens.contains(where: {
          $0.visibleFrame.contains(NSPoint(x: position[0], y: desktopTop - position[1] - 1))
        }) {
        setFrame(NSRect(x: position[0], y: desktopTop - position[1] - height,
                        width: width, height: height), display: true)
      } else {
        setFrame(NSRect(origin: frame.origin, size: NSSize(width: width, height: height)),
                 display: true)
        center()
      }
    }
    if args["maximized"] as? Bool == true && !isZoomed { zoom(nil) }
  }

  private func handleWindowCall(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let id = args["viewId"] as? Int64 else {
      result(FlutterMethodNotImplemented)
      return
    }
    switch call.method {
    case "configure":
      mainViewId = id
      configure(args)
      result(windowState())
    case "windowState":
      result(windowState())
    case "setWindow":
      switch args["key"] as? String {
      case "bounds":
        if let v = args["value"] as? [Double], v.count == 4 {
          setFrame(NSRect(x: v[0], y: desktopTop - v[1] - v[3], width: v[2], height: v[3]),
                   display: true)
        }
      case "minimumSize":
        if let v = args["value"] as? [Double], v.count == 2 {
          minSize = NSSize(width: v[0], height: v[1])
        }
      case "contentSize":
        if let v = args["value"] as? [Double], v.count == 2 {
          setContentSize(NSSize(width: v[0], height: v[1]))
        }
      case "aspectRatio":
        let value = args["value"] as? Double ?? 0
        contentAspectRatio = value > 0 ? NSSize(width: value, height: 1) : .zero
      case "title":
        title = args["value"] as? String ?? title
      case "showTitleBar":
        setTitleBar(args["value"] as? Bool ?? true)
      case "alwaysOnTop":
        level = args["value"] as? Bool == true ? .floating : .normal
      case "fullscreen":
        if styleMask.contains(.fullScreen) != (args["value"] as? Bool == true) {
          toggleFullScreen(nil)
        }
      case "dark":
        appearance = NSAppearance(named: args["value"] as? Bool == true ? .darkAqua : .aqua)
      case "show":
        if args["value"] as? Bool == true {
          if isMiniaturized { deminiaturize(nil) }
          makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
        } else {
          orderOut(nil)
        }
        notifyWindowChanged()
      case "drag":
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseDragged {
          performDrag(with: event)
        }
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func notifyWindowChanged() {
    windowChannel?.invokeMethod("windowChanged", arguments: windowState())
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if !interceptClose { return true }
    windowChannel?.invokeMethod("closeRequested", arguments: ["viewId": mainViewId])
    return false
  }

  func windowDidResize(_ notification: Notification) { notifyWindowChanged() }
  func windowDidMove(_ notification: Notification) { notifyWindowChanged() }
  func windowDidMiniaturize(_ notification: Notification) { notifyWindowChanged() }
  func windowDidDeminiaturize(_ notification: Notification) { notifyWindowChanged() }
  func windowDidBecomeKey(_ notification: Notification) {
    windowChannel?.invokeMethod("activated", arguments: ["viewId": mainViewId])
  }
}
