import Flutter
import UIKit
import GoogleMaps
import ARKit
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate {
  private var methodChannel: FlutterMethodChannel?
  // Strong instance property — prevents deallocation before user responds to permission prompt.
  private let locationManager = CLLocationManager()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let apiKey = Bundle.main.object(forInfoDictionaryKey: "MAPS_API_KEY") as? String ?? ""
    GMSServices.provideAPIKey(apiKey)
    print("DEBUG: [Post] AppDelegate GMSServices.provideAPIKey initialized for iOS with dynamic key")
    
    // Must call super first — this initializes the Flutter engine and sets window.rootViewController
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    
    // Assign delegate BEFORE requesting permission so locationManagerDidChangeAuthorization
    // fires on this instance when the user responds to the system prompt.
    locationManager.delegate = self
    locationManager.requestWhenInUseAuthorization()
    
    // Register all plugins with self (FlutterAppDelegate implements FlutterPluginRegistry)
    GeneratedPluginRegistrant.register(with: self)
    
    // rootViewController is now safely set after super.application returns
    if let controller = window?.rootViewController as? FlutterViewController {
        setupARKitChannel(controller: controller)
    }
    
    return result
  }


  // MARK: - Safe MethodChannel Bridge
  // AppDelegate owns ONLY the method channel for the geospatial bridge.
  // All ARKit/GARSession lifecycle is exclusively managed by ArCoreViewIOS.
  // Having two ARKit sessions (one here, one in ArCoreViewIOS) causes silent
  // camera/sensor conflicts that prevent GARSession from ever reaching TRACKING.
  func setupARKitChannel(controller: FlutterViewController) {
    self.methodChannel = FlutterMethodChannel(
      name: "com.postspatial.ar/geospatial",
      binaryMessenger: controller.binaryMessenger
    )

    self.methodChannel?.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      // anchorModel is handled natively by ArCoreViewIOS via the arcore_flutter_plugin
      // channel. This AppDelegate bridge is kept as a compatibility stub.
      if call.method == "anchorModel" {
        result(nil)
      } else if call.method == "startArSession" {
        // AR session lifecycle is owned by ArCoreViewIOS — acknowledge without action.
        print("DEBUG: [Post] startArSession received by AppDelegate stub (ArCoreViewIOS owns session)")
        result(true)
      } else if call.method == "stopArSession" {
        // AR session lifecycle is owned by ArCoreViewIOS — acknowledge without action.
        print("DEBUG: [Post] stopArSession received by AppDelegate stub (ArCoreViewIOS owns session)")
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    })
  }

  // MARK: - CLLocationManagerDelegate
  // Called when the user responds to the permission prompt (iOS 14+).
  // Restarts the ARKit session with .gravityAndHeading the instant access is granted,
  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      let status = manager.authorizationStatus
      guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
      guard ARWorldTrackingConfiguration.isSupported else { return }
      print("DEBUG: [Post] Location permission granted — ArCoreViewIOS will handle ARKit restart")
  }
}
