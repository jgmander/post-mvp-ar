import Flutter
import UIKit
import GoogleMaps
import ARKit
import SceneKit
import ARCoreGeospatial

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, ARSCNViewDelegate, ARSessionDelegate, GARSessionDelegate {
  private var arView: ARSCNView?
  private var methodChannel: FlutterMethodChannel?
  private var garSession: GARSession?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let apiKey = "AIzaSyDos1-Qi6u61x4im7B161B4Bmh2Tf5dU_8"
    GMSServices.provideAPIKey(apiKey)
    print("DEBUG: [Post] AppDelegate GMSServices.provideAPIKey initialized for iOS")
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Safe MethodChannel Bridge
  func setupARKitChannel(controller: FlutterViewController) {
    self.methodChannel = FlutterMethodChannel(name: "com.postspatial.ar/geospatial",
                                              binaryMessenger: controller.binaryMessenger)
    
    self.arView = ARSCNView(frame: controller.view.bounds)
    if let arView = self.arView {
        arView.delegate = self
        arView.session.delegate = self
    }

    do {
        self.garSession = try GARSession(apiKey: "AIzaSyDos1-Qi6u61x4im7B161B4Bmh2Tf5dU_8", bundleIdentifier: nil)
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
                config.worldAlignment = .gravity
                self.arView?.session.run(config)
                
                guard let garSession = self.garSession, let arFrame = self.arView?.session.currentFrame else {
                    result(FlutterError(code: "UNAVAILABLE", message: "AR Session not ready", details: nil))
                    return
                }

                do {
                    // 1. Temporary Earth Anchor
                    let garFrame = try? garSession.update(with: arFrame)
                    let altitude = garFrame?.earth?.cameraGeospatialTransform?.altitude ?? 0.0
                    let tempAnchor = try garSession.createAnchor(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), altitude: altitude, eastUpSouthQTarget: simd_quatf(angle: 0, axis: simd_float3(0,1,0)))
                    
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
                    let hitResults = garFrame?.raycast(origin, direction: direction) ?? []
                    var hitBuilding = false
                    var hitTransform: simd_float4x4?
                    
                    for hit in hitResults {
                        if let trackable = hit.trackable as? GARStreetscapeGeometry, trackable.type == .building {
                            hitBuilding = true
                            hitTransform = hit.transform
                            break
                        }
                    }
                    
                    // 4. Snap to mesh
                    if hitBuilding, let hitTransform = hitTransform {
                        _ = try garSession.createAnchor(transform: hitTransform)
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

  // MARK: - ARSessionDelegate
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
      do {
          _ = try self.garSession?.update(frame)
      } catch {
          print("GARSession update error")
      }
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

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
