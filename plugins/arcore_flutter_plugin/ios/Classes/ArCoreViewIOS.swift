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

        // ~4Hz proximity LOD + smooth distance-legibility boost for 3D stickers & caption cards
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
                        let visible = dist <= meta.maxDistance
                        meta.labelNode.isHidden = !visible
                        if visible && meta.maxDistance < 100.0 {
                            // Keep close-range (<8m) stickers compact on storefronts, then smoothly boost
                            // up to 2.25x at down-the-block distances (15m-50m) for 3x street legibility!
                            let boost = min(2.25, max(1.0, 1.0 + (dist - 8.0) * 0.042))
                            meta.labelNode.simdScale = simd_float3(repeating: boost)
                        }
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
        var r: CGFloat = 0.10, g: CGFloat = 0.55, b: CGFloat = 1.0, a: CGFloat = 0.94

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
                    r = CGFloat((colorMap["r"] as? NSNumber)?.doubleValue ?? 26) / 255.0
                    g = CGFloat((colorMap["g"] as? NSNumber)?.doubleValue ?? 140) / 255.0
                    b = CGFloat((colorMap["b"] as? NSNumber)?.doubleValue ?? 255) / 255.0
                    a = CGFloat((colorMap["a"] as? NSNumber)?.doubleValue ?? 240) / 255.0
                }
            }
        }

        let anchorSurface = (map["anchorSurface"] as? String)?.lowercased() ?? ""
        let isBalloon = radius > 1.2
        let isBuildingSticker = !isBalloon && anchorSurface == "building"

        // Building posts render as 3D Die-Cut Bumper Sticker Signs (no sphere orb).
        if isBuildingSticker {
            let container = SCNNode()
            container.name = name
            return container
        }

        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 48
        sphere.firstMaterial?.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: a)
        // Self-illumination keeps Electric Post Blue vivid at night and in storefront shadows
        sphere.firstMaterial?.emission.contents = UIColor(
            red: min(1.0, r * 0.46 + 0.04),
            green: min(1.0, g * 0.46 + 0.06),
            blue: min(1.0, b * 0.48 + 0.08),
            alpha: 1.0
        )
        sphere.firstMaterial?.lightingModel = .physicallyBased
        sphere.firstMaterial?.metalness.contents = 0.12
        sphere.firstMaterial?.roughness.contents = 0.22

        let node = SCNNode(geometry: sphere)
        node.name = name

        // Sky-safe contrast rim on Sky Balloons so Electric Post Blue pops against bright daytime blue sky
        if isBalloon {
            let halo = SCNTorus(ringRadius: radius * 1.04, pipeRadius: 0.085)
            halo.firstMaterial?.diffuse.contents = UIColor(white: 1.0, alpha: 0.95)
            halo.firstMaterial?.lightingModel = .constant
            let haloNode = SCNNode(geometry: halo)
            haloNode.name = name
            haloNode.eulerAngles = SCNVector3(0.24, 0, 0.10)
            node.addChildNode(haloNode)
        }

        return node
    }

    /// Wraps a caption into 1 or 2 balanced lines for crisp 3x storefront legibility.
    private func wrapSignLines(_ raw: String, maxLineChars: Int = 16, maxTotalChars: Int = 46) -> [String] {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
        let capped = collapsed.count > maxTotalChars
            ? String(collapsed.prefix(maxTotalChars - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : collapsed
        if capped.count <= maxLineChars {
            return [capped]
        }
        let words = capped.split(separator: " ").map(String.init)
        if words.count <= 1 {
            let mid = capped.index(capped.startIndex, offsetBy: min(maxLineChars, capped.count))
            return [String(capped[..<mid]), String(capped[mid...])]
        }
        var line1 = ""
        var splitIdx = 0
        let target = capped.count / 2
        for (idx, w) in words.enumerated() {
            let candidate = line1.isEmpty ? w : "\(line1) \(w)"
            if candidate.count <= max(maxLineChars, target + 4) && idx < words.count - 1 {
                line1 = candidate
                splitIdx = idx + 1
            } else {
                if line1.isEmpty {
                    line1 = w
                    splitIdx = 1
                }
                break
            }
        }
        let remainder = words[splitIdx...].joined(separator: " ")
        if remainder.isEmpty { return [line1] }
        let cappedLine2 = remainder.count > maxLineChars + 4
            ? String(remainder.prefix(maxLineChars + 3)).trimmingCharacters(in: .whitespaces) + "…"
            : remainder
        return [line1, cappedLine2]
    }

    /// Draws the trademark-distinct Post Folded-Note 'P' Spatial Mark in `rect`.
    private func drawPostBrandStamp(
        in rect: CGRect,
        fillColor: UIColor,
        glyphColor: UIColor,
        borderColor: UIColor
    ) {
        let w = rect.width
        let h = rect.height
        let ox = rect.minX
        let oy = rect.minY

        let left = ox + w * 0.12
        let right = ox + w * 0.88
        let top = oy + h * 0.08
        let bottom = oy + h * 0.79
        let r = w * 0.15
        let fold = w * 0.24

        let note = UIBezierPath()
        note.move(to: CGPoint(x: left + r, y: top))
        note.addLine(to: CGPoint(x: right - fold, y: top))
        note.addLine(to: CGPoint(x: right, y: top + fold))
        note.addLine(to: CGPoint(x: right, y: bottom - r))
        note.addQuadCurve(to: CGPoint(x: right - r, y: bottom), controlPoint: CGPoint(x: right, y: bottom))
        note.addLine(to: CGPoint(x: ox + w * 0.60, y: bottom))
        note.addLine(to: CGPoint(x: ox + w * 0.50, y: oy + h * 0.95))
        note.addLine(to: CGPoint(x: ox + w * 0.40, y: bottom))
        note.addLine(to: CGPoint(x: left + r, y: bottom))
        note.addQuadCurve(to: CGPoint(x: left, y: bottom - r), controlPoint: CGPoint(x: left, y: bottom))
        note.addLine(to: CGPoint(x: left, y: top + r))
        note.addQuadCurve(to: CGPoint(x: left + r, y: top), controlPoint: CGPoint(x: left, y: top))
        note.close()

        fillColor.setFill()
        note.fill()

        borderColor.setStroke()
        note.lineWidth = max(2.2, w * 0.055)
        note.lineJoinStyle = .round
        note.stroke()

        // Folded top-right sticky-note dog-ear flap
        let flap = UIBezierPath()
        flap.move(to: CGPoint(x: right - fold, y: top))
        flap.addLine(to: CGPoint(x: right - fold, y: top + fold * 0.78))
        flap.addQuadCurve(
            to: CGPoint(x: right - fold * 0.78, y: top + fold),
            controlPoint: CGPoint(x: right - fold, y: top + fold)
        )
        flap.addLine(to: CGPoint(x: right, y: top + fold))
        flap.close()
        glyphColor.withAlphaComponent(0.92).setFill()
        flap.fill()

        // Bold geometric 'P' monogram
        let stemX = ox + w * 0.36
        let stemTop = oy + h * 0.27
        let stemBottom = oy + h * 0.63
        let bowlMidY = oy + h * 0.46
        let bowlRadius = (bowlMidY - stemTop) * 0.5
        let bowlCenterX = (ox + w * 0.57) - bowlRadius

        let pPath = UIBezierPath()
        pPath.move(to: CGPoint(x: stemX, y: stemBottom))
        pPath.addLine(to: CGPoint(x: stemX, y: stemTop))
        pPath.addLine(to: CGPoint(x: bowlCenterX, y: stemTop))
        pPath.addArc(
            withCenter: CGPoint(x: bowlCenterX, y: stemTop + bowlRadius),
            radius: bowlRadius,
            startAngle: -.pi / 2,
            endAngle: .pi / 2,
            clockwise: true
        )
        pPath.addLine(to: CGPoint(x: stemX, y: bowlMidY))

        glyphColor.setStroke()
        pPath.lineWidth = max(3.0, w * 0.108)
        pPath.lineCapStyle = .round
        pPath.lineJoinStyle = .round
        pPath.stroke()
    }

    private func makePillPlaneNode(
        text: String,
        nodeName: String,
        isLive24h: Bool,
        isBuildingSticker: Bool = false,
        planeHeight: CGFloat
    ) -> SCNNode {
        let lines = wrapSignLines(text)
        let fontSize: CGFloat = isBuildingSticker ? 56 : 50
        let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = isBuildingSticker ? .left : .center
        paragraph.lineSpacing = 6

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]
        let joinedText = lines.joined(separator: "\n")
        let measured = (joinedText as NSString).boundingRect(
            with: CGSize(width: 1400, height: 600),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let textWidth = ceil(measured.width)
        let textHeight = ceil(measured.height)

        let postBlue = UIColor(red: 0.102, green: 0.549, blue: 1.0, alpha: 1.0)     // #1A8CFF
        let liveAmber = UIColor(red: 1.0, green: 0.722, blue: 0.180, alpha: 1.0)    // #FFB82E
        let darkSlate = UIColor(red: 0.043, green: 0.075, blue: 0.149, alpha: 0.96) // #0B1326

        let borderInset: CGFloat = 10
        let badgeTabWidth: CGFloat = isBuildingSticker ? 132 : 96
        let hPad: CGFloat = isBuildingSticker ? 38 : 34
        let vPad: CGFloat = isBuildingSticker ? 30 : 24

        let imgWidth = ceil(borderInset * 2 + badgeTabWidth + textWidth + hPad * 2)
        let imgHeight = ceil(max(textHeight + vPad * 2 + borderInset * 2, isBuildingSticker ? 168 : 136))
        let canvasSize = CGSize(width: imgWidth, height: imgHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let cardImage = renderer.image { ctx in
            let cg = ctx.cgContext
            let outerRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 6, dy: 6)
            let cornerRad: CGFloat = isBuildingSticker ? 30 : min(44, outerRect.height * 0.42)

            // Crisp pure-white die-cut vinyl sticker base (guarantees contrast against dark facades AND blue sky)
            let outerPath = UIBezierPath(roundedRect: outerRect, cornerRadius: cornerRad)
            UIColor.white.setFill()
            outerPath.fill()

            // Inner sign face
            let innerRect = outerRect.insetBy(dx: isBuildingSticker ? 10 : 7, dy: isBuildingSticker ? 10 : 7)
            let innerRad = max(14, cornerRad - (isBuildingSticker ? 8 : 6))
            let innerPath = UIBezierPath(roundedRect: innerRect, cornerRadius: innerRad)
            darkSlate.setFill()
            innerPath.fill()

            // Left signature Post brand tab clipped inside innerPath
            cg.saveGState()
            innerPath.addClip()
            let tabRect = CGRect(
                x: innerRect.minX,
                y: innerRect.minY,
                width: badgeTabWidth,
                height: innerRect.height
            )
            (isLive24h ? liveAmber : postBlue).setFill()
            UIRectFill(tabRect)

            // Subtle accent divider line
            let dividerRect = CGRect(
                x: tabRect.maxX - 2,
                y: innerRect.minY,
                width: 3,
                height: innerRect.height
            )
            UIColor(white: 1.0, alpha: 0.35).setFill()
            UIRectFill(dividerRect)
            cg.restoreGState()

            // Stamp our trademark-distinct Post Folded-Note 'P' mark inside the brand tab
            let stampSide = min(badgeTabWidth * 0.68, innerRect.height * 0.66)
            let stampRect = CGRect(
                x: innerRect.minX + (badgeTabWidth - stampSide) / 2,
                y: innerRect.minY + (innerRect.height - stampSide) / 2,
                width: stampSide,
                height: stampSide
            )
            drawPostBrandStamp(
                in: stampRect,
                fillColor: isLive24h ? darkSlate : postBlue,
                glyphColor: .white,
                borderColor: .white
            )

            // Electric Post Blue / Live Amber inner hairline accent
            let accentStroke = isLive24h ? liveAmber : postBlue
            accentStroke.withAlphaComponent(0.9).setStroke()
            innerPath.lineWidth = 3.0
            innerPath.stroke()

            // Draw crisp 3x 1-or-2-line caption
            let contentLeft = innerRect.minX + badgeTabWidth + hPad
            let contentWidth = innerRect.maxX - hPad - contentLeft
            let textRect = CGRect(
                x: contentLeft,
                y: innerRect.minY + (innerRect.height - textHeight) / 2,
                width: contentWidth,
                height: textHeight
            )
            (joinedText as NSString).draw(in: textRect, withAttributes: attributes)
        }

        let planeWidth: CGFloat = planeHeight * (imgWidth / max(imgHeight, 1))
        let plane = SCNPlane(width: planeWidth, height: planeHeight)
        plane.firstMaterial?.diffuse.contents = cardImage
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.isDoubleSided = true
        plane.firstMaterial?.writesToDepthBuffer = isBuildingSticker

        let signRoot = SCNNode()
        signRoot.name = nodeName

        let faceNode = SCNNode(geometry: plane)
        faceNode.name = nodeName
        signRoot.addChildNode(faceNode)

        // Give Building Bumper Stickers subtle 3D physical plaque depth (2.6cm white vinyl edge)
        // so angled sidewalk views read like a real mounted storefront blade sign!
        if isBuildingSticker {
            let plaque = SCNBox(
                width: planeWidth * 0.985,
                height: planeHeight * 0.97,
                length: 0.026,
                chamferRadius: 0.012
            )
            plaque.firstMaterial?.diffuse.contents = UIColor(white: 0.98, alpha: 0.96)
            plaque.firstMaterial?.lightingModel = .constant
            let plaqueNode = SCNNode(geometry: plaque)
            plaqueNode.name = nodeName
            plaqueNode.position = SCNVector3(0, 0, -0.016)
            signRoot.addChildNode(plaqueNode)
        }

        // Upright Y-axis billboarding: angles gently toward sidewalk walkers down the block,
        // and smoothly rotates flat against the storefront facade when standing directly in front!
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        signRoot.constraints = [billboard]
        return signRoot
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
        let anchorSurface = (map["anchorSurface"] as? String)?.lowercased() ?? ""
        let isBalloon = sphereRadius > 1.2
        let isBuildingSticker = !isBalloon && anchorSurface == "building"

        var metaEntries: [(labelNode: SCNNode, maxDistance: Float)] = []

        // Sky Balloon vertical glowing dual-core tether (~3x thicker!) + bold ground target ring
        if isBalloon && altitudeAboveGround >= 5.0 {
            let sheathColor = isLive24h
                ? UIColor(red: 1.0, green: 0.722, blue: 0.180, alpha: 0.78)
                : UIColor(red: 0.102, green: 0.549, blue: 1.0, alpha: 0.78)

            let tetherHeight = max(2.0, altitudeAboveGround - Double(sphereRadius) - 0.12)
            let tetherCenterY = -Float(sphereRadius) - Float(tetherHeight / 2.0)

            // Outer Electric Post Blue / Amber glow sheath (3x thicker: 0.098m radius = ~20cm beam)
            let outerCylinder = SCNCylinder(radius: 0.098, height: CGFloat(tetherHeight))
            outerCylinder.firstMaterial?.diffuse.contents = sheathColor
            outerCylinder.firstMaterial?.lightingModel = .constant
            outerCylinder.firstMaterial?.writesToDepthBuffer = false
            let outerTetherNode = SCNNode(geometry: outerCylinder)
            outerTetherNode.name = name
            outerTetherNode.position = SCNVector3(0, tetherCenterY, 0)
            parentNode.addChildNode(outerTetherNode)

            // Crisp pure-white inner luminous core (0.040m radius) so the string pops day & night
            let coreCylinder = SCNCylinder(radius: 0.040, height: CGFloat(tetherHeight))
            coreCylinder.firstMaterial?.diffuse.contents = UIColor(white: 1.0, alpha: 0.94)
            coreCylinder.firstMaterial?.lightingModel = .constant
            coreCylinder.firstMaterial?.writesToDepthBuffer = false
            let coreTetherNode = SCNNode(geometry: coreCylinder)
            coreTetherNode.name = name
            coreTetherNode.position = SCNVector3(0, tetherCenterY, 0)
            parentNode.addChildNode(coreTetherNode)

            let ring = SCNTorus(ringRadius: 0.52, pipeRadius: 0.055)
            ring.firstMaterial?.diffuse.contents = sheathColor.withAlphaComponent(0.90)
            ring.firstMaterial?.lightingModel = .constant
            let ringNode = SCNNode(geometry: ring)
            ringNode.name = name
            ringNode.position = SCNVector3(0, -Float(altitudeAboveGround) + 0.12, 0)
            parentNode.addChildNode(ringNode)
        }

        let rawInput = (map["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveText = rawInput.isEmpty ? (isBuildingSticker ? "Post" : "") : rawInput
        guard !effectiveText.isEmpty else {
            if !metaEntries.isEmpty { labelMetaMap[name] = metaEntries }
            return
        }

        let displayText = isLive24h ? "⚡ \(effectiveText)" : effectiveText
        let lineCount = wrapSignLines(displayText).count

        if isBuildingSticker {
            // Building Bumper Sticker replaces the sphere directly at (0, 0, 0) on the facade!
            // Compact 0.48m-0.62m height up close (<8m) + automatic 2.25x distance boost down the block!
            let stickerHeight: CGFloat = lineCount > 1 ? 0.62 : 0.48
            let stickerNode = makePillPlaneNode(
                text: displayText,
                nodeName: name,
                isLive24h: isLive24h,
                isBuildingSticker: true,
                planeHeight: stickerHeight
            )
            stickerNode.position = SCNVector3(0, 0, 0)
            parentNode.addChildNode(stickerNode)
            metaEntries.append((labelNode: stickerNode, maxDistance: 58.0))
        } else {
            // 1. Primary 3x floating sign card directly above Ground Pin orb or Sky Balloon
            let planeHeight: CGFloat
            if isBalloon {
                planeHeight = lineCount > 1 ? 2.55 : 2.15
            } else {
                planeHeight = lineCount > 1 ? 0.58 : 0.46
            }
            let skyLabelNode = makePillPlaneNode(
                text: displayText,
                nodeName: name,
                isLive24h: isLive24h,
                isBuildingSticker: false,
                planeHeight: planeHeight
            )
            skyLabelNode.position = SCNVector3(0, Float(sphereRadius) + Float(planeHeight * 0.58) + 0.16, 0)
            parentNode.addChildNode(skyLabelNode)
            let maxVisibleDist: Float = isBalloon ? 150.0 : 55.0
            metaEntries.append((labelNode: skyLabelNode, maxDistance: maxVisibleDist))

            // 2. Eye-level tether signpost (1.35m above ground) for Sky Balloons when <= 28m away
            if isBalloon && altitudeAboveGround >= 5.0 {
                let shortChars = 26
                let shortClean = effectiveText.count > shortChars
                    ? String(effectiveText.prefix(shortChars - 1)) + "…"
                    : effectiveText
                let eyeLabelNode = makePillPlaneNode(
                    text: "🎈 ↑ \(shortClean)",
                    nodeName: name,
                    isLive24h: isLive24h,
                    isBuildingSticker: false,
                    planeHeight: 0.46
                )
                eyeLabelNode.position = SCNVector3(0, Float(1.35 - altitudeAboveGround), 0)
                parentNode.addChildNode(eyeLabelNode)
                metaEntries.append((labelNode: eyeLabelNode, maxDistance: 28.0))
            }
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
