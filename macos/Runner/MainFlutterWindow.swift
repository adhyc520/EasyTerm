import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 默认与最小尺寸由 Flutter window_manager 同步；此处仅作原生侧兜底
    self.minSize = NSSize(width: 900, height: 560)

    super.awakeFromNib()
  }
}
