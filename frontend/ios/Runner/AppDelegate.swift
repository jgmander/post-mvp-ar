import Flutter
import UIKit
import GoogleMaps
import ARKit
import SceneKit
import ARCoreGeospatial
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, ARSCNViewDelegate, ARSessionDelegate, GARSessionDelegate, CLLocationManagerDelegate {
  private var arView: ARSCNView?
  private var methodChannel: FlutterMethodChannel?
  private var garSession: GARSession?
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
  func setupARKitChannel(controller: FlutterViewController) {
    self.methodChannel = FlutterMethodChannel(name: "com.postspatial.ar/geospatial",
                                              binaryMessenger: controller.binaryMessenger)
    
    self.arView = ARSCNView(frame: controller.view.bounds)
    if let arView = self.arView {
        arView.delegate = self
        arView.session.delegate = self
        arView.isHidden = true
        controller.view.addSubview(arView)
    }

    do {
        let apiKey = Bundle.main.object(forInfoDictionaryKey: "MAPS_API_KEY") as? String ?? ""
        self.garSession = try GARSession(apiKey: apiKey, bundleIdentifier: nil)
        var error: NSError?
        let config = GARSessionConfiguration()
        config.geospatialMode = .enabled
        config.streetscapeGeometryMode = .enabled
        self.garSession?.setConfiguration(config, error: &error)
        self.garSession?.delegate = self
    } catch {
        print("Failed to initialize GARSession")
    }

    self.methodChannel?.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "anchorModel" {
        guard let args = call.arguments as? [String: Any],
              let lat = args["lat"] as? Double,
              let lng = args["lng"] as? Double,
              let assetPath = args["assetPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing arguments", details: nil))
          return
        }
        print("DEBUG: [Post] Received anchorModel call: lat=\(lat), lng=\(lng), assetPath=\(assetPath)")
        
        self.methodChannel?.invokeMethod("onTrackingStateChanged", arguments: "LOCALIZING")

        if #available(iOS 14.0, *) {
            if ARWorldTrackingConfiguration.isSupported {
                let config = ARWorldTrackingConfiguration()
                // SPRINT 6.3 FIX: .gravityAndHeading is required by GARSession for VPS.
                // Without compass fusion, GARSession starves silently and never reaches TRACKING.
                config.worldAlignment = .gravityAndHeading
                self.arView?.session.run(config)
                
                guard let garSession = self.garSession, let arFrame = self.arView?.session.currentFrame else {
                    result(FlutterError(code: "UNAVAILABLE", message: "AR Session not ready", details: nil))
                    return
                }

                do {
                    // 1. Temporary Earth Anchor
                    let garFrame = try? garSession.update(arFrame)
                    let altitude = garFrame?.earth?.cameraGeospatialTransform?.altitude ?? 0.0
                    let tempAnchor = try garSession.createAnchor(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), altitude: altitude, eastUpSouthQAnchor: simd_quatf(angle: 0, axis: simd_float3(0,1,0)))
                    
                    let cameraTransform = arFrame.camera.transform
                    let anchorTransform = tempAnchor.transform
                    
                    // 2. Vector towards temporary anchor
                    let dx = anchorTransform.columns.3.x - cameraTransform.columns.3.x
                    let dy = anchorTransform.columns.3.y - cameraTransform.columns.3.y
                    let dz = anchorTransform.columns.3.z - cameraTransform.columns.3.z
                    
                    let distance = sqrt(dx*dx + dy*dy + dz*dz)
                    let direction = simd_float3(dx/distance, dy/distance, dz/distance)
                    let origin = simd_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
                    
                    // 3. Raycast against Streetscape Geometry
                    let hitResults = try? garSession.raycastStreetscapeGeometry(origin: origin, direction: direction)
                    let hits = hitResults ?? []
                    var hitBuilding = false
                    var hitTransform: simd_float4x4?
                    var hitGeometry: GARStreetscapeGeometry?
                    
                    for hit in hits {
                        if let trackable = hit.streetscapeGeometry, trackable.type == .building {
                            hitBuilding = true
                            hitTransform = hit.worldTransform
                            hitGeometry = trackable
                            break
                        }
                    }
                    
                    // 4. Snap to mesh
                    if hitBuilding, let hitTransform = hitTransform, let hitGeometry = hitGeometry {
                        _ = try garSession.createAnchor(geometry: hitGeometry, transform: hitTransform)
                        print("DEBUG: [Post] Snapped to BUILDING mesh")
                        garSession.remove(tempAnchor)
                        result(true)
                    } else {
                        print("DEBUG: [Post] Earth anchor created at \(lat), \(lng) (No building hit)")
                        result(true)
                    }
                } catch {
                    print("Error creating GAR anchor: \(error)")
                    result(FlutterError(code: "ANCHOR_ERROR", message: "Failed to create GAR anchor", details: nil))
                }
            } else {
                result(FlutterError(code: "UNSUPPORTED", message: "ARWorldTrackingConfiguration not supported.", details: nil))
            }
        } else {
            result(FlutterError(code: "UNSUPPORTED", message: "iOS 14.0 or newer is required.", details: nil))
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    })
  }

  // MARK: - CLLocationManagerDelegate
  // Called when the user responds to the permission prompt (iOS 14+).
  // Restarts the ARKit session with .gravityAndHeading the instant access is granted,
  // eliminating the boot-time race condition identified in Sprint 6.2.
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      let status = manager.authorizationStatus
      guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
      guard ARWorldTrackingConfiguration.isSupported else { return }
      let config = ARWorldTrackingConfiguration()
      config.worldAlignment = .gravityAndHeading
      self.arView?.session.run(config, options: [.resetTracking])
      print("DEBUG: [Post] Location permission granted — restarted ARKit with .gravityAndHeading")
  }

  // MARK: - ARSessionDelegate
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
      // Continuously pass Apple's ARFrame into Google's GARSession
      _ = try? self.garSession?.update(frame)
  }

  // MARK: - GARSessionDelegate
  func session(_ session: GARSession, didUpdate earth: GAREarth?) {
      let stateString: String
      if earth?.trackingState == .tracking {
          stateString = "TRACKING"
      } else {
          stateString = "LOCALIZING"
      }
      self.methodChannel?.invokeMethod("onTrackingStateChanged", arguments: stateString)
  }

  // MARK: - ARSCNViewDelegate
  func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
      // GARSession handles tracking, returning nil to skip manual binding in POC
      return nil
  }
}
