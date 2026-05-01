import Flutter
import UIKit
import GoogleMaps
import ARKit
import SceneKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, ARSCNViewDelegate, ARSessionDelegate {
  private var arView: ARSCNView?

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
    
    // Scaffold ARSCNView overlay
    self.arView = ARSCNView(frame: controller.view.bounds)
    if let arView = self.arView {
        arView.delegate = self
        arView.session.delegate = self
        // Note: For a true POC, this view would be inserted underneath the transparent Flutter view.
        // controller.view.insertSubview(arView, at: 0)
    }

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
        
        // Start ARGeoTracking if supported
        if ARGeoTrackingConfiguration.isSupported {
            let config = ARGeoTrackingConfiguration()
            self.arView?.session.run(config)
            
            // Create ARGeoAnchor
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let geoAnchor = ARGeoAnchor(coordinate: coordinate)
            self.arView?.session.add(anchor: geoAnchor)
            print("DEBUG: [Post] Added ARGeoAnchor at \\(lat), \\(lng)")
            result(true)
        } else {
            result(FlutterError(code: "UNSUPPORTED", message: "ARGeoTrackingConfiguration is not supported on this device.", details: nil))
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    })

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - ARSCNViewDelegate
  func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
      guard let geoAnchor = anchor as? ARGeoAnchor else { return nil }
      print("DEBUG: [Post] Rendering node for ARGeoAnchor at \\(geoAnchor.coordinate.latitude), \\(geoAnchor.coordinate.longitude)")
      
      // Load the .usdz asset from the flutter bundle
      // Scaffolded logic:
      // let url = Bundle.main.url(forResource: "flutter_assets/assets/models/For_Sale_Sign", withExtension: "usdz")
      // return SCNReferenceNode(url: url)
      return SCNNode()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
