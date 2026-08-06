import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerMacosResizeCursors(viewController: flutterViewController)

    // 默认与最小尺寸由 Flutter window_manager 同步；此处仅作原生侧兜底
    self.minSize = NSSize(width: 900, height: 560)

    super.awakeFromNib()
  }
}

/// Flutter 引擎未映射对角缩放光标；从 HIServices 加载系统资源（与 Finder 同款）。
private func registerMacosResizeCursors(viewController: FlutterViewController) {
  let channel = FlutterMethodChannel(
    name: "easyterm/macos_resize_cursors",
    binaryMessenger: viewController.engine.binaryMessenger
  )
  channel.setMethodCallHandler { call, result in
    guard call.method == "activate",
          let args = call.arguments as? [String: Any],
          let kind = args["kind"] as? String
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    let cursorName: String
    switch kind {
    case "nwse":
      cursorName = "resizenorthwestsoutheast"
    case "nesw":
      cursorName = "resizenortheastsouthwest"
    default:
      result(
        FlutterError(
          code: "bad_kind",
          message: "Unknown resize cursor kind: \(kind)",
          details: nil
        )
      )
      return
    }
    let cursor = loadHiServicesCursor(named: cursorName) ?? NSCursor.resizeLeftRight
    cursor.set()
    // 同步 FlutterView._lastCursor，避免 cursorUpdate: 把光标打回箭头。
    syncFlutterLastCursor(viewController.view, cursor: cursor)
    result(nil)
  }
}

private func syncFlutterLastCursor(_ view: NSView, cursor: NSCursor) {
  let sel = NSSelectorFromString("didUpdateMouseCursor:")
  if view.responds(to: sel) {
    view.perform(sel, with: cursor)
  }
}

private func loadHiServicesCursor(named name: String) -> NSCursor? {
  let base =
    "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/"
    + "HIServices.framework/Versions/A/Resources/cursors"
  let dir = (base as NSString).appendingPathComponent(name)
  let imagePath = (dir as NSString).appendingPathComponent("cursor.pdf")
  let infoPath = (dir as NSString).appendingPathComponent("info.plist")
  guard let image = NSImage(contentsOfFile: imagePath),
        let info = NSDictionary(contentsOfFile: infoPath)
  else {
    return nil
  }
  let hotX = (info["hotx"] as? NSNumber)?.doubleValue ?? 8
  let hotY = (info["hoty"] as? NSNumber)?.doubleValue ?? 8
  return NSCursor(image: image, hotSpot: NSPoint(x: hotX, y: hotY))
}
