import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let apiKey = "AIzaSyDos1-Qi6u61x4im7B161B4Bmh2Tf5dU_8"
    GMSServices.provideAPIKey(apiKey)
    print("DEBUG: [Post] AppDelegate GMSServices.provideAPIKey initialized for iOS")
    
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let arChannel = FlutterMethodChannel(name: "com.postspatial.ar/geospatial",
                                              binaryMessenger: controller.binaryMessenger)
    arChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "anchorModel" {
        guard let args = call.arguments as? [String: Any],
              let lat = args["lat"] as? Double,
              let lng = args["lng"] as? Double,
              let assetPath = args["assetPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing arguments", details: nil))
          return
        }
        print("DEBUG: [Post] Received anchorModel call: lat=\\(lat), lng=\\(lng), assetPath=\\(assetPath)")
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    })

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
