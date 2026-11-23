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
    private var garAnchorMap: [UUID: (node: SCNNode, anchor: GARAnchor)] = [:]
    private var labelMetaMap: [String: [(labelNode: SCNNode, maxDistance: Float)]] = [:]
    private var pendingFutures: [String: GARFuture] = [:]

    // Geospatial state
    private var latestGeospatialTransform: GARGeospatialTransform?
    private var latestFrame: GARFrame?
    private var streetscapeGeometries: [GARStreetscapeGeometry] = []
    private var latestCenterTarget: [String: Any]?
    private var hasLiDARMesh: Bool = false

    // Throttle: fire center target updates at ~6Hz on state/distance change
    private var lastCenterSummaryKey: String = ""

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

        let isARKitSupported = ARWorldTrackingConfiguration.isSupported

        if isARKitSupported {
            // ARKit supported experience
            self.arView = ARSCNView(frame: frame)
            self.isARSupported = true
            print("DEBUG: [Post] Creating ARSCNView and calling setupARView()")
            setupARView()
        } else {
            // Unsupported hardware fallback
            self.isARSupported = false
            let reason = "This device does not support AR features."
            setupFallbackView(frame: frame, reason: reason, isDemoMode: false)
            debugLog("AR Unsupported: \(reason)")

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

        // Start ARKit session with world tracking (+ LiDAR mesh on Pro iPhones)
        let config = makeWorldTrackingConfig()
        
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

    private func makeWorldTrackingConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = [.horizontal, .vertical]
        if #available(iOS 13.4, *),
           ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            self.hasLiDARMesh = true
        } else {
            self.hasLiDARMesh = false
        }
        return config
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
        case "raycastCenter":
            raycastCenter(result: result)
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
            garAnchorMap[anchor.identifier] = (node: sphere, anchor: anchor)

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
            let future = try garSession.createAnchorOnRooftop(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                altitudeAboveRooftop: alt,
                eastUpSouthQAnchor: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            ) { [weak self] anchor, state in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.pendingFutures.removeValue(forKey: name)
                    if let anchor = anchor, state == .success {
                        self.removeExistingNodeIfPresent(name: name)
                        let sphere = self.createSphereNode(name: name, map: map)
                        self.attachLabelIfNeeded(to: sphere, name: name, map: map, altitudeAboveGround: alt)
                        sphere.simdTransform = anchor.transform
                        self.arView?.scene.rootNode.addChildNode(sphere)
                        self.nodeMap[name] = sphere
                        self.garAnchorMap[anchor.identifier] = (node: sphere, anchor: anchor)
                        self.methodChannel.invokeMethod("onRooftopAnchorResolved", arguments: [
                            "name": name,
                            "success": true,
                            "state": "SUCCESS"
                        ])
                    } else {
                        self.methodChannel.invokeMethod("onRooftopAnchorResolved", arguments: [
                            "name": name,
                            "success": false,
                            "state": "ERROR_\(state.rawValue)"
                        ])
                    }
                }
            }
            pendingFutures[name] = future
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

        // First check for node hits (spheres, floating caption pills, or sky-balloon tethers)
        let hitResults = arView.hitTest(location, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue
        ])
        for hit in hitResults {
            if let nodeName = hit.node.name, nodeMap[nodeName] != nil {
                debugLog("onNodeTap: \(nodeName)")
                methodChannel.invokeMethod("onNodeTap", arguments: nodeName)
                return
            }
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
        let config = makeWorldTrackingConfig()
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

        // Sync GARAnchor transforms to SCNNodes
        for anchor in validGarFrame.anchors {
            if let mapping = garAnchorMap[anchor.identifier] {
                mapping.node.simdTransform = anchor.transform
                mapping.node.isHidden = anchor.trackingState != .tracking
            }
        }

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
        }

        // ~6Hz center-crosshair raycast against Streetscape Geometry + close-range surfaces
        if earthFrameCounter % 10 == 0,
           let earth = validGarFrame.earth,
           earth.trackingState == .tracking {
            if let target = performCenterRaycast(session: session, frame: frame) {
                let surfaceType = target["surfaceType"] as? String ?? "none"
                let distBucket = Int(((target["distance"] as? Double) ?? 0.0).rounded())
                let summaryKey = "\(surfaceType)_\(distBucket)"
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.latestCenterTarget = target
                    if summaryKey != self.lastCenterSummaryKey {
                        self.lastCenterSummaryKey = summaryKey
                        self.methodChannel.invokeMethod("onCenterHitBuilding", arguments: target)
                    }
                }
            }
        }

        // Ensure SceneKit camera far-clip supports block-scale Sky Balloons (500m vs default 100m)
        if let cam = arView?.pointOfView?.camera, cam.zFar < 500.0 {
            cam.zFar = 500.0
        }

        // ~4Hz proximity LOD check for floating 3D caption pills (prevents clutter at distance)
        if earthFrameCounter % 15 == 0 {
            let camCol = frame.camera.transform.columns.3
            let camPos = simd_float3(camCol.x, camCol.y, camCol.z)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                for (_, entries) in self.labelMetaMap {
                    for meta in entries {
                        guard let parent = meta.labelNode.parent, !parent.isHidden else {
                            meta.labelNode.isHidden = true
                            continue
                        }
                        let worldCol = meta.labelNode.simdWorldTransform.columns.3
                        let labelPos = simd_float3(worldCol.x, worldCol.y, worldCol.z)
                        let dist = simd_distance(camPos, labelPos)
                        meta.labelNode.isHidden = dist > meta.maxDistance
                    }
                }
            }
        }
    }

    // MARK: - Center Crosshair Laser-Raycast (Streetscape + Close-Range Surface)

    private func raycastCenter(result: @escaping FlutterResult) {
        if let arView = arView,
           let currentFrame = arView.session.currentFrame,
           let fresh = performCenterRaycast(session: arView.session, frame: currentFrame) {
            self.latestCenterTarget = fresh
            result(fresh)
            return
        }
        result(self.latestCenterTarget)
    }

    private func performCenterRaycast(session: ARSession, frame: ARFrame) -> [String: Any]? {
        guard let garSession = garSession,
              let earth = latestFrame?.earth,
              earth.trackingState == .tracking else {
            return nil
        }

        let camTransform = frame.camera.transform
        let origin = simd_float3(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
        let forward = -simd_normalize(simd_float3(camTransform.columns.2.x, camTransform.columns.2.y, camTransform.columns.2.z))

        // 1. Close-range physical object check (trees, dog-waste stations, patio tables, signs).
        // On LiDAR Pro iPhones (`sceneReconstruction = .mesh`), `.estimatedPlane` intersects the
        // true hardware LiDAR scene mesh within its 5.0m laser range. On non-LiDAR iPhones,
        // require `.existingPlaneGeometry` so leaves/bark never trigger noisy depth guesses.
        var closeHitTransform: simd_float4x4?
        var closeHitDist: Float = Float.greatestFiniteMagnitude
        let localTarget: ARRaycastQuery.Target = hasLiDARMesh ? .estimatedPlane : .existingPlaneGeometry
        let maxLocalRange: Float = hasLiDARMesh ? 5.0 : 6.0
        let planeQuery = ARRaycastQuery(origin: origin, direction: forward, allowing: localTarget, alignment: .any)
        if let firstPlane = session.raycast(planeQuery).first {
            let pCol = firstPlane.worldTransform.columns.3
            let pPos = simd_float3(pCol.x, pCol.y, pCol.z)
            let d = simd_distance(origin, pPos)
            if d >= 0.35 && d <= maxLocalRange {
                closeHitTransform = firstPlane.worldTransform
                closeHitDist = d
            }
        }

        // 2. Streetscape Geometry raycast (buildings + terrain up to 55m across the street)
        var ssHit: GARStreetscapeGeometryRaycastResult?
        let rayException = ObjCExceptionCatcher.catchException {
            if let hits = try? garSession.raycastStreetscapeGeometry(origin: origin, direction: forward) {
                ssHit = hits.first(where: { $0.distance >= 0.4 && $0.distance <= 55.0 })
            }
        }
        if rayException != nil {
            ssHit = nil
        }

        var chosenSurface = "none"
        var targetWorldMatrix = matrix_identity_float4x4
        var hitDistance: Float = 0.0
        var altAboveTerrain: Double = 1.4

        if let localTransform = closeHitTransform,
           (ssHit == nil || closeHitDist < (ssHit!.distance - 1.0)) {
            // Close-range LiDAR mesh / verified plane wins; step 0.25m back toward camera
            // so the 0.6m sphere sits on the front face of a tree trunk or post.
            chosenSurface = "surface"
            hitDistance = closeHitDist
            let rawCol = localTransform.columns.3
            let rawPos = simd_float3(rawCol.x, rawCol.y, rawCol.z)
            let pullback = min(Float(0.25), hitDistance * Float(0.25))
            let adjPos = rawPos - forward * pullback
            targetWorldMatrix.columns.3 = simd_float4(adjPos.x, adjPos.y, adjPos.z, 1.0)
            altAboveTerrain = Double(min(max((rawPos.y - origin.y) + 1.45, 1.15), 4.5))
        } else if let validSS = ssHit {
            let isBuilding = (validSS.streetscapeGeometry.type == .building)
            chosenSurface = isBuilding ? "building" : "terrain"
            hitDistance = validSS.distance
            let rawCol = validSS.worldTransform.columns.3
            let rawPos = simd_float3(rawCol.x, rawCol.y, rawCol.z)

            if isBuilding {
                // Pull 0.7m back toward camera so 0.6m sphere sits cleanly outside facade glass
                let pullback = min(Float(0.7), hitDistance * Float(0.35))
                let adjPos = rawPos - forward * pullback
                targetWorldMatrix.columns.3 = simd_float4(adjPos.x, adjPos.y, adjPos.z, 1.0)
                altAboveTerrain = Double(min(max((rawPos.y - origin.y) + 1.45, 1.35), 18.0))
            } else {
                targetWorldMatrix = validSS.worldTransform
                altAboveTerrain = 1.35
            }
        } else {
            // Open sky / far horizon fallback: project 3.0m horizontally in front of camera
            var flatForward = simd_float3(forward.x, 0.0, forward.z)
            if simd_length(flatForward) < 0.01 {
                flatForward = simd_float3(0.0, 0.0, -1.0)
            } else {
                flatForward = simd_normalize(flatForward)
            }
            let projPos = origin + flatForward * Float(3.0)
            targetWorldMatrix.columns.3 = simd_float4(projPos.x, origin.y, projPos.z, 1.0)
            hitDistance = 3.0
            altAboveTerrain = 1.35
            chosenSurface = "none"
        }

        var resolvedGeo: GARGeospatialTransform?
        let geoException = ObjCExceptionCatcher.catchException {
            resolvedGeo = try? garSession.geospatialTransform(transform: targetWorldMatrix)
        }
        if geoException != nil || resolvedGeo == nil {
            guard let camGeo = latestGeospatialTransform else { return nil }
            return [
                "isBuilding": false,
                "hasTarget": false,
                "surfaceType": "camera",
                "distance": 0.0,
                "latitude": camGeo.coordinate.latitude,
                "longitude": camGeo.coordinate.longitude,
                "altitudeAboveTerrain": 1.35
            ]
        }

        let geo = resolvedGeo!
        return [
            "isBuilding": chosenSurface == "building",
            "hasTarget": chosenSurface != "none",
            "surfaceType": chosenSurface,
            "distance": Double(hitDistance),
            "latitude": geo.coordinate.latitude,
            "longitude": geo.coordinate.longitude,
            "altitudeAboveTerrain": altAboveTerrain
        ]
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

    private func removeExistingNodeIfPresent(name: String) {
        if let node = nodeMap[name] {
            node.removeFromParentNode()
            nodeMap.removeValue(forKey: name)
            labelMetaMap.removeValue(forKey: name)

            if let anchorId = garAnchorMap.first(where: { $0.value.node == node })?.key,
               let mapping = garAnchorMap[anchorId] {
                garAnchorMap.removeValue(forKey: anchorId)
                garSession?.remove(mapping.anchor)
            }
            debugLog("Removed node: \(name)")
        }
    }

    private func removeNode(name: String, result: FlutterResult) {
        if let pending = pendingFutures.removeValue(forKey: name) {
            _ = pending.cancel()
        }
        removeExistingNodeIfPresent(name: name)
        result(nil)
    }

    // MARK: - SceneKit Node Helpers

    private func createSphereNode(name: String, map: [String: Any]) -> SCNNode {
        var radius: CGFloat = 0.3
        var r: CGFloat = 0, g: CGFloat = 0.90, b: CGFloat = 1.0, a: CGFloat = 0.88

        // Parse shape from Flutter args (ArCoreMaterial serializes color as [alpha, red, green, blue])
        if let shapeMap = map["shape"] as? [String: Any] {
            radius = CGFloat((shapeMap["radius"] as? NSNumber)?.doubleValue ?? 0.3)
            if let matList = shapeMap["materials"] as? [[String: Any]],
               let firstMat = matList.first {
                if let colorArr = firstMat["color"] as? [NSNumber], colorArr.count >= 4 {
                    a = CGFloat(colorArr[0].doubleValue) / 255.0
                    r = CGFloat(colorArr[1].doubleValue) / 255.0
                    g = CGFloat(colorArr[2].doubleValue) / 255.0
                    b = CGFloat(colorArr[3].doubleValue) / 255.0
                } else if let colorMap = firstMat["color"] as? [String: Any] {
                    r = CGFloat((colorMap["r"] as? NSNumber)?.doubleValue ?? 0) / 255.0
                    g = CGFloat((colorMap["g"] as? NSNumber)?.doubleValue ?? 230) / 255.0
                    b = CGFloat((colorMap["b"] as? NSNumber)?.doubleValue ?? 255) / 255.0
                    a = CGFloat((colorMap["a"] as? NSNumber)?.doubleValue ?? 230) / 255.0
                }
            }
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

    private func makePillPlaneNode(
        text: String,
        nodeName: String,
        isLive24h: Bool,
        planeHeight: CGFloat
    ) -> SCNNode {
        let font = UIFont.systemFont(ofSize: 28, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: 0.94, green: 0.96, blue: 1.0, alpha: 1.0)
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let hPad: CGFloat = 28
        let vPad: CGFloat = 16
        let imgWidth = ceil(textSize.width + hPad * 2)
        let imgHeight = ceil(textSize.height + vPad * 2)
        let canvasSize = CGSize(width: imgWidth, height: imgHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let pillImage = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 3, dy: 3)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)

            UIColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 0.88).setFill()
            path.fill()

            let borderColor = isLive24h
                ? UIColor(red: 1.0, green: 0.72, blue: 0.18, alpha: 0.95)
                : UIColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 0.90)
            borderColor.setStroke()
            path.lineWidth = 3.5
            path.stroke()

            let textOrigin = CGPoint(
                x: (canvasSize.width - textSize.width) / 2,
                y: (canvasSize.height - textSize.height) / 2
            )
            (text as NSString).draw(at: textOrigin, withAttributes: attributes)
        }

        let planeWidth: CGFloat = planeHeight * (imgWidth / max(imgHeight, 1))
        let plane = SCNPlane(width: planeWidth, height: planeHeight)
        plane.firstMaterial?.diffuse.contents = pillImage
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.isDoubleSided = true
        plane.firstMaterial?.writesToDepthBuffer = false

        let labelNode = SCNNode(geometry: plane)
        labelNode.name = nodeName
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        labelNode.constraints = [billboard]
        return labelNode
    }

    private func attachLabelIfNeeded(
        to parentNode: SCNNode,
        name: String,
        map: [String: Any],
        altitudeAboveGround: Double
    ) {
        let isLive24h = (map["isLive24h"] as? Bool) ?? false
        var sphereRadius: CGFloat = 0.6
        if let shapeMap = map["shape"] as? [String: Any],
           let rNum = shapeMap["radius"] as? NSNumber {
            sphereRadius = CGFloat(rNum.doubleValue)
        }
        let isBalloon = sphereRadius > 1.2

        var metaEntries: [(labelNode: SCNNode, maxDistance: Float)] = []

        // Sky Balloon vertical glowing tether + ground ring so close-range users (2m-20m)
        // immediately see the vertical sky string rising from eye level up to 15m!
        if isBalloon && altitudeAboveGround >= 5.0 {
            let accentColor = isLive24h
                ? UIColor(red: 1.0, green: 0.72, blue: 0.18, alpha: 0.55)
                : UIColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 0.55)

            let tetherHeight = max(2.0, altitudeAboveGround - Double(sphereRadius) - 0.15)
            let cylinder = SCNCylinder(radius: 0.032, height: CGFloat(tetherHeight))
            cylinder.firstMaterial?.diffuse.contents = accentColor
            cylinder.firstMaterial?.lightingModel = .constant
            cylinder.firstMaterial?.writesToDepthBuffer = false
            let tetherNode = SCNNode(geometry: cylinder)
            tetherNode.name = name
            tetherNode.position = SCNVector3(0, -Float(sphereRadius) - Float(tetherHeight / 2.0), 0)
            parentNode.addChildNode(tetherNode)

            let ring = SCNTorus(ringRadius: 0.30, pipeRadius: 0.03)
            ring.firstMaterial?.diffuse.contents = accentColor.withAlphaComponent(0.75)
            ring.firstMaterial?.lightingModel = .constant
            let ringNode = SCNNode(geometry: ring)
            ringNode.name = name
            ringNode.position = SCNVector3(0, -Float(altitudeAboveGround) + 0.12, 0)
            parentNode.addChildNode(ringNode)
        }

        guard let rawLabel = map["label"] as? String else {
            if !metaEntries.isEmpty { labelMetaMap[name] = metaEntries }
            return
        }
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if !metaEntries.isEmpty { labelMetaMap[name] = metaEntries }
            return
        }

        let maxChars = 34
        let cleanText = trimmed.count > maxChars
            ? String(trimmed.prefix(maxChars - 1)) + "…"
            : trimmed
        let displayText = isLive24h ? "⚡ \(cleanText)" : cleanText

        // 1. Primary floating caption pill directly above the sphere / sky balloon
        let planeHeight: CGFloat = isBalloon ? 0.85 : 0.26
        let skyLabelNode = makePillPlaneNode(
            text: displayText,
            nodeName: name,
            isLive24h: isLive24h,
            planeHeight: planeHeight
        )
        skyLabelNode.position = SCNVector3(0, Float(sphereRadius) + Float(planeHeight * 0.65) + 0.15, 0)
        parentNode.addChildNode(skyLabelNode)
        let maxVisibleDist: Float = isBalloon ? 140.0 : 28.0
        metaEntries.append((labelNode: skyLabelNode, maxDistance: maxVisibleDist))

        // 2. Eye-level tether signpost (1.35m above ground) for Sky Balloons when standing <= 22m away
        if isBalloon && altitudeAboveGround >= 5.0 {
            let shortChars = 24
            let shortClean = trimmed.count > shortChars
                ? String(trimmed.prefix(shortChars - 1)) + "…"
                : trimmed
            let eyeLabelNode = makePillPlaneNode(
                text: "🎈 ↑ \(shortClean)",
                nodeName: name,
                isLive24h: isLive24h,
                planeHeight: 0.23
            )
            eyeLabelNode.position = SCNVector3(0, Float(1.35 - altitudeAboveGround), 0)
            parentNode.addChildNode(eyeLabelNode)
            metaEntries.append((labelNode: eyeLabelNode, maxDistance: 22.0))
        }

        labelMetaMap[name] = metaEntries
    }

    // MARK: - Session Control

    private func resumeSession() {
        guard let arView = arView else { return }
        let config = makeWorldTrackingConfig()
        
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
        for (_, future) in pendingFutures {
            _ = future.cancel()
        }
        pendingFutures.removeAll()
        garSession = nil
        nodeMap.removeAll()
        garAnchorMap.removeAll()
        labelMetaMap.removeAll()
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
            let future = try garSession.createAnchorOnTerrain(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                altitudeAboveTerrain: alt,
                eastUpSouthQAnchor: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            ) { [weak self] anchor, state in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.pendingFutures.removeValue(forKey: name)
                    if let anchor = anchor, state == .success {
                        self.removeExistingNodeIfPresent(name: name)
                        let sphere = self.createSphereNode(name: name, map: map)
                        self.attachLabelIfNeeded(to: sphere, name: name, map: map, altitudeAboveGround: alt)
                        sphere.simdTransform = anchor.transform
                        self.arView?.scene.rootNode.addChildNode(sphere)
                        self.nodeMap[name] = sphere
                        self.garAnchorMap[anchor.identifier] = (node: sphere, anchor: anchor)
                        self.methodChannel.invokeMethod("onTerrainAnchorResolved", arguments: [
                            "name": name,
                            "success": true,
                            "state": "SUCCESS"
                        ])
                    } else {
                        self.methodChannel.invokeMethod("onTerrainAnchorResolved", arguments: [
                            "name": name,
                            "success": false,
                            "state": "ERROR_\(state.rawValue)"
                        ])
                    }
                }
            }
            pendingFutures[name] = future
            result(nil)
        } catch {
            result(FlutterError(code: "ANCHOR_ERROR", message: error.localizedDescription, details: nil))
        }
    }
}
