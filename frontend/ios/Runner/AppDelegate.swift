import Flutter
import UIKit
import GoogleMaps
import ARKit
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate {
  private var methodChannel: FlutterMethodChannel?
  private var httpChannel: FlutterMethodChannel?
  // Strong instance property — prevents deallocation before user responds to permission prompt.
  private let locationManager = CLLocationManager()
  // Native URLSession with iOS Wi-Fi Assist / cellular failover (avoids dart:io dead-Wi-Fi socket drops)
  private lazy var nativeUrlSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.allowsCellularAccess = true
    config.allowsExpensiveNetworkAccess = true
    config.allowsConstrainedNetworkAccess = true
    config.waitsForConnectivity = false
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 8.5
    config.timeoutIntervalForResource = 12.0
    return URLSession(configuration: config)
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let apiKey = Bundle.main.object(forInfoDictionaryKey: "MAPS_API_KEY") as? String ?? ""
    GMSServices.provideAPIKey(apiKey)
    GMSServices.addInternalUsageAttributionID("gmp_git_agentskills_v1")
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
        setupNativeHttpChannel(controller: controller)
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

  // MARK: - Native URLSession Bridge (Wi-Fi Assist & Seamless Cellular Failover)
  func setupNativeHttpChannel(controller: FlutterViewController) {
    self.httpChannel = FlutterMethodChannel(
      name: "com.postspatial.net/http",
      binaryMessenger: controller.binaryMessenger
    )
    self.httpChannel?.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard call.method == "request",
            let args = call.arguments as? [String: Any],
            let method = args["method"] as? String,
            let urlString = args["url"] as? String,
            let url = URL(string: urlString) else {
        result(FlutterError(code: "INVALID_ARGS", message: "Invalid HTTP arguments", details: nil))
        return
      }
      guard let session = self?.nativeUrlSession else {
        result(FlutterError(code: "NO_SESSION", message: "URLSession unavailable", details: nil))
        return
      }

      var req = URLRequest(url: url)
      req.httpMethod = method
      req.cachePolicy = .reloadIgnoringLocalCacheData
      req.allowsCellularAccess = true
      if #available(iOS 13.0, *) {
        req.allowsExpensiveNetworkAccess = true
        req.allowsConstrainedNetworkAccess = true
      }
      if let timeoutMs = args["timeoutMs"] as? Int, timeoutMs > 0 {
        req.timeoutInterval = Double(timeoutMs) / 1000.0
      } else {
        req.timeoutInterval = 8.5
      }
      if let headers = args["headers"] as? [String: String] {
        for (k, v) in headers {
          req.setValue(v, forHTTPHeaderField: k)
        }
      }
      if let body = args["body"] as? String {
        req.httpBody = body.data(using: .utf8)
      }

      let task = session.dataTask(with: req) { data, response, error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "NETWORK_ERROR", message: error.localizedDescription, details: nil))
            return
          }
          let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
          let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
          result([
            "statusCode": statusCode,
            "body": bodyStr
          ])
        }
      }
      task.resume()
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
