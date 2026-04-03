import Flutter
import UIKit

/// Main plugin class — registers the ArCoreViewFactory as a PlatformView.
public class SwiftArcoreFlutterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let factory = ArCoreViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "arcore_flutter_plugin")
    }
}
