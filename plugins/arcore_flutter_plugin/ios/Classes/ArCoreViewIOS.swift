import Flutter
import UIKit
import ARKit
import SceneKit
import CoreLocation
import ARCoreGARSession
import ARCoreGeospatial

// GARSession imports — only available if ARCore pod is linked
// We use conditional compilation and ObjCExceptionCatcher to handle
// devices where ARCore Geospatial is not supported (e.g., iPad).

/// Native iOS implementation of the ARCore Flutter Plugin.
/// Uses ARKit's ARSession + Google's GARSession for Geospatial VPS.
/// Renders 3D content via SceneKit (ARSCNView).
///
/// SAFETY: If the device does not support ARKit world tracking or
/// GARSession (e.g., iPad), the view shows a graceful fallback label
/// instead of crashing.
public class ArCoreViewIOS: NSObject, FlutterPlatformView, ARSessionDelegate, ARSCNViewDelegate, CLLocationManagerDelegate {

    private var arView: ARSCNView?
    private var fallbackView: UIView?
    private var garSession: GARSession?
    private let methodChannel: FlutterMethodChannel
    private var isDebug = false
    private var isARSupported = false

    // Node tracking
    private var nodeMap: [String: SCNNode] = [:]

    // Geospatial state
    private var latestGeospatialTransform: GARGeospatialTransform?
    private var latestFrame: GARFrame?
    private var streetscapeGeometries: [GARStreetscapeGeometry] = []

    // Throttle: only fire onCenterHitBuilding on value change
    private var lastCenterHitState: Bool = false

    // Diagnostic: throttle earth state logging to ~1/sec
    private var earthFrameCounter: Int = 0

    // Persistent location manager (avoid re-creating throwaway instances)
    private let locationManager = CLLocationManager()

    // MARK: - Init

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
        self.methodChannel = FlutterMethodChannel(
            name: "arcore_flutter_plugin_\(viewId)",
            binaryMessenger: messenger
        )
        super.init()
        self.methodChannel.setMethodCallHandler(handle)
        // Assign delegate immediately so locationManagerDidChangeAuthorization
        // fires on this instance (not AppDelegate) to restart the ARKit session.
        self.locationManager.delegate = self
        print("DEBUG: [Post] ArCoreViewIOS init - ViewId: \(viewId)")

        // Parse creation args
        if let dict = args as? [String: Any] {
            isDebug = dict["debug"] as? Bool ?? false
        }

        // Broad capability check instead of hardware whitelist
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let isARKitSupported = ARWorldTrackingConfiguration.isSupported

        if isARKitSupported && !isIPad {
            // Full iPhone AR experience
            self.arView = ARSCNView(frame: frame)
            self.isARSupported = true
            print("DEBUG: [Post] Creating ARSCNView and calling setupARView()")
            setupARView()
        } else {
            // iPad / unsupported device — Demo Mode with graceful fallback
            self.isARSupported = false
            let reason = isIPad ? "iPad detected. Running in Demo Mode — spatial anchoring requires iPhone with GPS." : "This device does not fully support AR features."
            setupFallbackView(frame: frame, reason: reason, isDemoMode: true)
            debugLog("Demo Mode activated: \(reason)")

            DispatchQueue.main.async {
                self.methodChannel.invokeMethod("onCompatibilityError", arguments: [
                    "isFullySupported": false,
                    "isARSupported": false,
                    "hasGPS": false,
                    "isDemoMode": true,
                    "reason": reason,
                    "deviceModel": "unsupported"
                ])
            }
        }
    }

    public func view() -> UIView {
        if let arView = arView {
            print("DEBUG: [Post] Returning ARSCNView to Flutter")
            return arView
        }
        print("DEBUG: [Post] Returning FallbackView to Flutter")
        return fallbackView ?? UIView()
    }

    // MARK: - Fallback View (for unsupported devices like iPad)

    private func setupFallbackView(frame: CGRect, reason: String, isDemoMode: Bool) {
        let container = UIView(frame: frame)
        container.backgroundColor = UIColor(red: 0.04, green: 0.055, blue: 0.1, alpha: 1.0) // #0A0E1A

        // Icon
        let iconLabel = UILabel()
        iconLabel.text = isDemoMode ? "📱" : "⚠️"
        iconLabel.font = UIFont.systemFont(ofSize: 48)
        iconLabel.textAlignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = UILabel()
        titleLabel.text = isDemoMode
            ? "Spatial Features Not Available"
            : "AR Not Supported"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Subtitle
        let subtitleLabel = UILabel()
        subtitleLabel.text = reason
        subtitleLabel.textColor = UIColor(red: 0.0, green: 0.9, blue: 0.9, alpha: 1.0)
        subtitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Hint
        let hintLabel = UILabel()
        hintLabel.text = "For the full AR experience, use Post on iPhone."
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        hintLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconLabel, titleLabel, subtitleLabel, hintLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32)
        ])

        self.fallbackView = container

        // Notify Flutter that AR is not available
        methodChannel.invokeMethod("onError", arguments: [
            "error": "AR_NOT_SUPPORTED",
            "message": "ARWorldTrackingConfiguration is not supported on this device."
        ])
    }

    // MARK: - AR Setup

    private func setupARView() {
        print("DEBUG: [Post] setupARView() started")
        guard let arView = arView else {
            print("DEBUG: [Post] setupARView() early exit: arView is nil")
            return
        }

        arView.delegate = self
        arView.session.delegate = self
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true
        arView.showsStatistics = isDebug

        // Initialize GARSession with the API key — wrapped in ObjC exception catcher
        // because GARSession throws NSExceptions on unsupported devices (iPad),
        // which Swift's do/catch cannot intercept.
        let exception = ObjCExceptionCatcher.catchException {
            do {
                self.garSession = try GARSession(apiKey: self.getAPIKey(), bundleIdentifier: nil)

                var config = GARSessionConfiguration()
                config.geospatialMode = .enabled
                config.streetscapeGeometryMode = .enabled

                var error: NSError?
                self.garSession?.setConfiguration(config, error: &error)
                if let error = error {
                    self.debugLog("GARSession config error: \(error.localizedDescription)")
                } else {
                    self.debugLog("GARSession configured: Geospatial + StreetscapeGeometry ENABLED")
                }
            } catch {
                self.debugLog("GARSession init error (Swift): \(error.localizedDescription)")
            }
        }

        if let exception = exception {
            debugLog("GARSession init threw NSException: \(exception.name) — \(exception.reason ?? "unknown")")
            debugLog("Continuing without GARSession (AR camera will still work)")
            garSession = nil
            // Notify Flutter about degraded capabilities
            methodChannel.invokeMethod("onError", arguments: [
                "error": "GEOSPATIAL_NOT_SUPPORTED",
                "message": "GARSession is not available on this device: \(exception.reason ?? "unknown")"
            ])
        }

        // Start ARKit session with world tracking
        let config = ARWorldTrackingConfiguration()
        let authStatus = locationManager.authorizationStatus
        if authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways {
            config.worldAlignment = .gravityAndHeading
        } else {
            // SPRINT 6.3: Boot with .gravityAndHeading regardless.
            // GARSession requires compass fusion from frame 0. The delegate callback
            // locationManagerDidChangeAuthorization will restart the session once
            // the user grants access, so there is no functional loss.
            config.worldAlignment = .gravityAndHeading
        }
        
        let runException = ObjCExceptionCatcher.catchException {
            self.arView?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
        
        if let runException = runException {
            print("DEBUG: [Post] ARKit session.run threw NSException: \(runException.name)")
            debugLog("ARKit session.run threw NSException: \(runException.name)")
        } else {
            print("DEBUG: [Post] ARKit session started successfully. Alignment: \(config.worldAlignment.rawValue)")
        }
        
        debugLog("ARKit session started (alignment: \(config.worldAlignment.rawValue))")
    }

    private func getAPIKey() -> String {
        // PRIORITY 1: MAPS_API_KEY from Info.plist — the same unrestricted key Android
        // uses via AndroidManifest meta-data "com.google.ar.core.API_KEY".
        // This key has no API restrictions so GARSession is always authorized.
        if let key = Bundle.main.infoDictionary?["MAPS_API_KEY"] as? String, !key.isEmpty {
            print("DEBUG: [Post] Using MAPS_API_KEY from Info.plist for GARSession")
            return key
        }
        // PRIORITY 2: GoogleService-Info.plist Firebase key (requires ARCore in restriction list)
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let key = dict["API_KEY"] as? String {
            print("DEBUG: [Post] Using API Key from GoogleService-Info.plist")
            return key
        }
        // PRIORITY 3: Hardcoded fallback (unrestricted debug key)
        print("DEBUG: [Post] Using Fallback API Key")
        return "AIzaSyDos1-Qi6u61x4im7B161B4Bmh2Tf5dU_8"
    }

    // MARK: - MethodChannel Handler

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // If AR is not supported, return graceful errors for AR-specific methods
        if !isARSupported {
            switch call.method {
            case "init", "dispose", "resume":
                result(nil) // No-op
            default:
                result(FlutterError(code: "AR_NOT_SUPPORTED",
                                    message: "AR is not available on this device",
                                    details: nil))
            }
            return
        }

        switch call.method {
        case "init":
            initAR(call: call, result: result)
        case "addArCoreNode":
            if let map = call.arguments as? [String: Any] {
                addNode(map: map, result: result)
            }
        case "addArCoreNodeWithAnchor":
            if let map = call.arguments as? [String: Any] {
                addNodeWithAnchor(map: map, result: result)
            }
        case "removeARCoreNode":
            if let map = call.arguments as? [String: Any],
               let name = map["nodeName"] as? String {
                removeNode(name: name, result: result)
            }
        case "getGeospatialPose":
            getGeospatialPose(result: result)
        case "addEarthAnchorNode":
            if let map = call.arguments as? [String: Any] {
                addEarthAnchorNode(map: map, result: result)
            }
        case "resolveAnchorOnRooftopAsync":
            if let map = call.arguments as? [String: Any] {
                resolveAnchorOnRooftopAsync(map: map, result: result)
            }
        case "resolveAnchorOnTerrainAsync":
            if let map = call.arguments as? [String: Any] {
                resolveAnchorOnTerrainAsync(map: map, result: result)
            }
        case "getTrackingState":
            let state = arView?.session.currentFrame?.camera.trackingState
            let stateStr: String
            switch state {
            case .normal: stateStr = "TRACKING"
            case .limited: stateStr = "PAUSED"
            case .notAvailable: stateStr = "STOPPED"
            default: stateStr = "STOPPED"
            }
            methodChannel.invokeMethod("getTrackingState", arguments: stateStr)
            result(nil)
        case "primeLandmarks":
            result(nil) // No-op, same as Android
        case "dispose":
            dispose()
            result(nil)
        case "resume":
            resumeSession()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Init AR (mirrors arScenViewInit)

    private func initAR(call: FlutterMethodCall, result: FlutterResult) {
        debugLog("initAR")

        if let args = call.arguments as? [String: Any] {
            let enableTap = args["enableTapRecognizer"] as? Bool ?? false
            if enableTap {
                let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                arView?.addGestureRecognizer(tapGesture)
            }
        }
        result(nil)
    }

    // MARK: - Geospatial Pose (mirrors getGeospatialPose)

    private func getGeospatialPose(result: FlutterResult) {
        // If Earth has locked, return the full precision pose.
        if let transform = latestGeospatialTransform {
            let map: [String: Any] = [
                "latitude": transform.coordinate.latitude,
                "longitude": transform.coordinate.longitude,
                "altitude": transform.altitude,
                "heading": transform.heading,
                "accuracy": transform.horizontalAccuracy
            ]
            debugLog("AUDIT: GeospatialPose acc=\(transform.horizontalAccuracy)m")
            result(map)
            return
        }

        // SPRINT 6.3 FIX: While still LOCALIZING, return a partial pose with a
        // sentinel accuracy of 999.0 — matching Android ARCore's behavior exactly.
        // Without this, _currentPose stays null in Flutter and the VPS scanning
        // badge (top-right) never renders, giving the user zero visual feedback.
        let earth = latestFrame?.earth
        let failureReason: String
        switch earth?.earthState {
        case .errorInternal: failureReason = "INTERNAL_ERROR"
        case .errorNotAuthorized: failureReason = "NOT_AUTHORIZED"
        case .errorResourceExhausted: failureReason = "RESOURCE_EXHAUSTED"
        default: failureReason = "LOCALIZING"
        }

        let partialMap: [String: Any] = [
            "latitude": 0.0,
            "longitude": 0.0,
            "altitude": 0.0,
            "heading": 0.0,
            "accuracy": 999.0,
            "trackingFailureReason": failureReason
        ]
        debugLog("AUDIT: GeospatialPose LOCALIZING — returning sentinel pose")
        result(partialMap)
    }

    // MARK: - Earth Anchor (mirrors addEarthAnchorNode)

    private func addEarthAnchorNode(map: [String: Any], result: @escaping FlutterResult) {
        guard let garSession = garSession else {
            result(FlutterError(code: "UNAVAILABLE", message: "GARSession not initialized", details: nil))
            return
        }
        guard latestGeospatialTransform != nil else {
            result(FlutterError(code: "UNAVAILABLE", message: "Earth not tracking", details: nil))
            return
        }

        let lat = (map["latitude"] as? NSNumber)?.doubleValue ?? 0.0
        let lng = (map["longitude"] as? NSNumber)?.doubleValue ?? 0.0
        let alt = (map["altitude"] as? NSNumber)?.doubleValue ?? 0.0
        let name = map["name"] as? String ?? "node_\(Int.random(in: 1000...9999))"

        do {
            let anchor = try garSession.createAnchor(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                altitude: alt,
                eastUpSouthQAnchor: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            )
            debugLog("Earth anchor created at \(lat), \(lng), \(alt)")

            // Create a visual sphere (matching Android's cyan sphere)
            let sphere = createSphereNode(name: name, map: map)
            sphere.simdTransform = anchor.transform
            arView?.scene.rootNode.addChildNode(sphere)
            nodeMap[name] = sphere

            result(nil)
        } catch {
            result(FlutterError(code: "ANCHOR_ERROR",
                                message: error.localizedDescription,
                                details: nil))
        }
    }

    // MARK: - Rooftop Anchor (mirrors resolveAnchorOnRooftopAsync)

    private func resolveAnchorOnRooftopAsync(map: [String: Any], result: @escaping FlutterResult) {
        guard let garSession = garSession else {
            result(FlutterError(code: "UNAVAILABLE", message: "GARSession not initialized", details: nil))
            return
        }

        let lat = (map["latitude"] as? NSNumber)?.doubleValue ?? 0.0
        let lng = (map["longitude"] as? NSNumber)?.doubleValue ?? 0.0
        let alt = (map["altitude"] as? NSNumber)?.doubleValue ?? 0.0
        let name = map["name"] as? String ?? "rooftop_\(Int.random(in: 1000...9999))"

        do {
            let rooftopAnchor = try garSession.createAnchorOnRooftop(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                altitudeAboveRooftop: alt,
                eastUpSouthQAnchor: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            ) { [weak self] anchor, state in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if let anchor = anchor {
                        let sphere = self.createSphereNode(name: name, map: map)
                        sphere.simdTransform = anchor.transform
                        self.arView?.scene.rootNode.addChildNode(sphere)
                        self.nodeMap[name] = sphere
                        self.methodChannel.invokeMethod("onRooftopAnchorResolved", arguments: [
                            "name": name,
                            "success": true,
                            "state": "SUCCESS"
                        ])
                    } else {
                        self.methodChannel.invokeMethod("onRooftopAnchorResolved", arguments: [
                            "name": name,
                            "success": false,
                            "state": "ERROR"
                        ])
                    }
                }
            }
            result(nil)
        } catch {
            result(FlutterError(code: "ROOFTOP_ERROR",
                                message: error.localizedDescription,
                                details: nil))
        }
    }

    // MARK: - Tap Handling (mirrors onSingleTap)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let arView = arView else { return }
        let location = gesture.location(in: arView)

        // First check for node hits
        let hitResults = arView.hitTest(location, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue
        ])
        if let hit = hitResults.first, let nodeName = hit.node.name, nodeMap[nodeName] != nil {
            debugLog("onNodeTap: \(nodeName)")
            methodChannel.invokeMethod("onNodeTap", arguments: nodeName)
            return
        }

        // Then check StreetscapeGeometry via GARSession raycast
        if let garFrame = latestFrame {
            var hitNodeType = "UNKNOWN"
            var hitLat = 0.0
            var hitLng = 0.0
            var hitAlt = 0.0

            for geometry in streetscapeGeometries {
                let type = geometry.type
                hitNodeType = type == .building ? "BUILDING" : "TERRAIN"
                if let transform = latestGeospatialTransform {
                    hitLat = transform.coordinate.latitude
                    hitLng = transform.coordinate.longitude
                    hitAlt = transform.altitude
                }
                break // Use first geometry hit
            }

            debugLog("AUDIT: Hit StreetscapeGeometry of type: \(hitNodeType)")
            methodChannel.invokeMethod("onPlaneTap", arguments: [
                [
                    "distance": 1.0,
                    "pose": [
                        "translation": [0.0, 0.0, -1.0],
                        "rotation": [0.0, 0.0, 0.0, 1.0]
                    ],
                    "nodeType": hitNodeType,
                    "latitude": hitLat,
                    "longitude": hitLng,
                    "altitude": hitAlt
                ]
            ])
        }
    }

    // MARK: - CLLocationManagerDelegate
    // Fires the moment the user grants location permission.
    // Immediately restarts ARKit with .gravityAndHeading so GARSession
    // gets compass-fused frames without requiring an app restart.
    @available(iOS 14.0, *)
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        guard isARSupported, let arView = arView else { return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        let exception = ObjCExceptionCatcher.catchException {
            arView.session.run(config, options: [.resetTracking])
        }
        if exception == nil {
            print("DEBUG: [Post] Permission granted — ARKit restarted with .gravityAndHeading")
        }
    }

    // MARK: - ARSessionDelegate (mirrors sceneUpdateListener)

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Update GARSession with the latest ARKit frame
        guard let garSession = garSession else { return }

        var garFrame: GARFrame?
        let exception = ObjCExceptionCatcher.catchException {
            do {
                garFrame = try garSession.update(frame)
            } catch {
                // Expected if not tracking yet
            }
        }
        
        if let exception = exception {
            debugLog("GARSession update threw NSException: \(exception.name). Disabling GARSession gracefully.")
            self.garSession = nil
            return
        }
        
        guard let validGarFrame = garFrame else { return }
        self.latestFrame = validGarFrame

        // Update geospatial transform
        if let earth = validGarFrame.earth,
           earth.trackingState == .tracking {
            latestGeospatialTransform = earth.cameraGeospatialTransform
        }

        // DIAGNOSTIC: Throttled earth state log (~1/sec at 60fps) — always on, bypasses isDebug
        earthFrameCounter += 1
        if earthFrameCounter % 60 == 0 {
            if let earth = validGarFrame.earth {
                let ts: String
                switch earth.trackingState {
                case .tracking: ts = "TRACKING"
                case .paused:   ts = "PAUSED"
                case .stopped:  ts = "STOPPED"
                @unknown default: ts = "UNKNOWN"
                }
                let es: String
                switch earth.earthState {
                case .enabled:                es = "enabled"
                case .errorInternal:          es = "errorInternal"
                case .errorNotAuthorized:     es = "errorNotAuthorized ⚠️ API key issue"
                case .errorResourceExhausted: es = "errorResourceExhausted"
                @unknown default:             es = "unknown(\(earth.earthState.rawValue))"
                }
                let acc = latestGeospatialTransform?.horizontalAccuracy ?? 999.0
                print("DEBUG: [Post] GARSession earth=\(es) tracking=\(ts) acc=\(String(format: "%.1f", acc))m")
            } else {
                print("DEBUG: [Post] GARSession earth=nil (frame \(earthFrameCounter))")
            }
        }

        // Update streetscape geometries
        if let geometries = validGarFrame.streetscapeGeometries {
            streetscapeGeometries = geometries

            // THROTTLE: Only fire onCenterHitBuilding on value CHANGE (not every frame)
            let hasBuildingInCenter = geometries.contains { $0.type == .building }
            if hasBuildingInCenter != lastCenterHitState {
                lastCenterHitState = hasBuildingInCenter
                methodChannel.invokeMethod("onCenterHitBuilding", arguments: hasBuildingInCenter)
            }
        }
    }

    // MARK: - Node Management

    private func addNode(map: [String: Any], result: FlutterResult) {
        let name = map["name"] as? String ?? "node_\(Int.random(in: 1000...9999))"
        let sphere = createSphereNode(name: name, map: map)

        // Position relative to camera
        if let posMap = map["position"] as? [String: Any] {
            let x = (posMap["x"] as? NSNumber)?.floatValue ?? 0
            let y = (posMap["y"] as? NSNumber)?.floatValue ?? 0
            let z = (posMap["z"] as? NSNumber)?.floatValue ?? 0
            sphere.position = SCNVector3(x, y, z)
        }

        arView?.scene.rootNode.addChildNode(sphere)
        nodeMap[name] = sphere
        result(nil)
    }

    private func addNodeWithAnchor(map: [String: Any], result: FlutterResult) {
        let name = map["name"] as? String ?? "node_\(Int.random(in: 1000...9999))"
        let sphere = createSphereNode(name: name, map: map)

        guard let frame = arView?.session.currentFrame else {
            result(FlutterError(code: "NO_FRAME", message: "No AR frame available", details: nil))
            return
        }

        // Place 1m in front of camera
        var translation = matrix_identity_float4x4
        translation.columns.3.z = -1.0
        let transform = simd_mul(frame.camera.transform, translation)
        let anchor = ARAnchor(name: name, transform: transform)
        arView?.session.add(anchor: anchor)

        sphere.simdTransform = transform
        arView?.scene.rootNode.addChildNode(sphere)
        nodeMap[name] = sphere
        result(nil)
    }

    private func removeNode(name: String, result: FlutterResult) {
        if let node = nodeMap[name] {
            node.removeFromParentNode()
            nodeMap.removeValue(forKey: name)
            debugLog("Removed node: \(name)")
        }
        result(nil)
    }

    // MARK: - SceneKit Node Helpers

    private func createSphereNode(name: String, map: [String: Any]) -> SCNNode {
        var radius: CGFloat = 0.3
        var r: CGFloat = 0, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1

        // Parse shape from Flutter args (matching Android FlutterArCoreNode)
        if let shapeMap = map["shape"] as? [String: Any] {
            radius = CGFloat((shapeMap["radius"] as? NSNumber)?.doubleValue ?? 0.3)
        }
        if let materialsArr = map["shape"] as? [String: Any],
           let matList = materialsArr["materials"] as? [[String: Any]],
           let firstMat = matList.first,
           let colorMap = firstMat["color"] as? [String: Any] {
            r = CGFloat((colorMap["r"] as? NSNumber)?.doubleValue ?? 0) / 255.0
            g = CGFloat((colorMap["g"] as? NSNumber)?.doubleValue ?? 255) / 255.0
            b = CGFloat((colorMap["b"] as? NSNumber)?.doubleValue ?? 255) / 255.0
            a = CGFloat((colorMap["a"] as? NSNumber)?.doubleValue ?? 255) / 255.0
        }

        let sphere = SCNSphere(radius: radius)
        sphere.firstMaterial?.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: a)
        sphere.firstMaterial?.lightingModel = .physicallyBased
        sphere.firstMaterial?.metalness.contents = 0.3
        sphere.firstMaterial?.roughness.contents = 0.4

        let node = SCNNode(geometry: sphere)
        node.name = name
        return node
    }

    // MARK: - Session Control

    private func resumeSession() {
        guard let arView = arView else { return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        
        let exception = ObjCExceptionCatcher.catchException {
            arView.session.run(config)
        }
        
        if let exception = exception {
            debugLog("ARKit session resume threw NSException: \(exception.name)")
        } else {
            debugLog("ARKit session resumed with gravityAndHeading")
        }
    }

    private func dispose() {
        arView?.session.pause()
        garSession = nil
        nodeMap.removeAll()
        debugLog("ARCore iOS disposed")
    }

    // MARK: - Debug

    private func debugLog(_ message: String) {
        if isDebug {
            print("[ArCoreIOS] \(message)")
        }
    }

    // MARK: - Terrain Anchor

    private func resolveAnchorOnTerrainAsync(map: [String: Any], result: @escaping FlutterResult) {
        guard let garSession = garSession else {
            result(FlutterError(code: "UNAVAILABLE", message: "GARSession not initialized", details: nil))
            return
        }

        let lat = (map["latitude"] as? NSNumber)?.doubleValue ?? 0.0
        let lng = (map["longitude"] as? NSNumber)?.doubleValue ?? 0.0
        let alt = (map["altitude"] as? NSNumber)?.doubleValue ?? 0.0
        let name = map["name"] as? String ?? "terrain_\(Int.random(in: 1000...9999))"

        do {
            let terrainAnchor = try garSession.createAnchorOnTerrain(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                altitudeAboveTerrain: alt,
                eastUpSouthQAnchor: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            ) { [weak self] anchor, state in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if let anchor = anchor {
                        let sphere = self.createSphereNode(name: name, map: map)
                        sphere.simdTransform = anchor.transform
                        self.arView?.scene.rootNode.addChildNode(sphere)
                        self.nodeMap[name] = sphere
                        self.methodChannel.invokeMethod("onTerrainAnchorResolved", arguments: [
                            "name": name,
                            "success": true,
                            "state": "SUCCESS"
                        ])
                    } else {
                        self.methodChannel.invokeMethod("onTerrainAnchorResolved", arguments: [
                            "name": name,
                            "success": false,
                            "state": "ERROR"
                        ])
                    }
                }
            }
            result(nil)
        } catch {
            result(FlutterError(code: "ANCHOR_ERROR", message: error.localizedDescription, details: nil))
        }
    }
}
