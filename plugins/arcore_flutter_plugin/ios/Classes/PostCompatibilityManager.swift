import Foundation
import ARKit
import CoreLocation

/// Comprehensive hardware compatibility checker for Post.
/// Ensures the app never crashes on launch regardless of device capabilities.
public class PostCompatibilityManager {

    /// Result of the compatibility check.
    public struct CompatibilityResult {
        public let isFullySupported: Bool
        public let isARSupported: Bool
        public let hasGPS: Bool
        public let isDemoMode: Bool
        public let reason: String
        public let deviceModel: String

        public func toDictionary() -> [String: Any] {
            return [
                "isFullySupported": isFullySupported,
                "isARSupported": isARSupported,
                "hasGPS": hasGPS,
                "isDemoMode": isDemoMode,
                "reason": reason,
                "deviceModel": deviceModel
            ]
        }
    }

    /// Known iPad model prefixes (Wi-Fi only models lack GPS).
    /// Wi-Fi+Cellular iPads have GPS; Wi-Fi-only do not.
    private static let wifiOnlyiPadModels: Set<String> = [
        // iPad Air M3 Wi-Fi only models (from crash report: iPad15,3)
        "iPad15,3", "iPad15,4",
        // Common Wi-Fi-only iPads (odd numbers are typically Wi-Fi only)
        "iPad13,1", "iPad13,2",  // iPad Air 4
        "iPad13,16", "iPad13,17", // iPad Air 5
        "iPad14,1", "iPad14,2",  // iPad mini 6
    ]

    /// Perform all hardware compatibility checks.
    public static func checkCompatibility() -> CompatibilityResult {
        let deviceModel = getDeviceModel()
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let isARKitSupported = ARWorldTrackingConfiguration.isSupported
        let hasGPS = checkGPSAvailability(deviceModel: deviceModel)

        // Full support: ARKit + GPS (iPhone with ARKit)
        if isARKitSupported && hasGPS && !isIPad {
            return CompatibilityResult(
                isFullySupported: true,
                isARSupported: true,
                hasGPS: true,
                isDemoMode: false,
                reason: "Full AR and Geospatial support available.",
                deviceModel: deviceModel
            )
        }

        // iPad with ARKit but possibly no GPS → Demo Mode
        if isIPad && isARKitSupported {
            return CompatibilityResult(
                isFullySupported: false,
                isARSupported: true,
                hasGPS: hasGPS,
                isDemoMode: true,
                reason: "iPad detected. Running in Demo Mode — spatial anchoring requires iPhone with GPS.",
                deviceModel: deviceModel
            )
        }

        // iPad without ARKit → Demo Mode (basic UI only)
        if isIPad {
            return CompatibilityResult(
                isFullySupported: false,
                isARSupported: false,
                hasGPS: hasGPS,
                isDemoMode: true,
                reason: "This iPad does not support AR. Running in Demo Mode.",
                deviceModel: deviceModel
            )
        }

        // iPhone without ARKit (very old device)
        if !isARKitSupported {
            return CompatibilityResult(
                isFullySupported: false,
                isARSupported: false,
                hasGPS: hasGPS,
                isDemoMode: true,
                reason: "This device does not support ARKit. Running in Demo Mode.",
                deviceModel: deviceModel
            )
        }

        // iPhone with ARKit but no GPS (should not happen, but defensive)
        return CompatibilityResult(
            isFullySupported: false,
            isARSupported: true,
            hasGPS: false,
            isDemoMode: true,
            reason: "GPS is not available. Running in Demo Mode.",
            deviceModel: deviceModel
        )
    }

    /// Check if the device has GPS capability.
    private static func checkGPSAvailability(deviceModel: String) -> Bool {
        // All iPhones have GPS
        if UIDevice.current.userInterfaceIdiom == .phone {
            return true
        }

        // iPads: check if it's a known Wi-Fi-only model
        if wifiOnlyiPadModels.contains(deviceModel) {
            return false
        }

        // For unknown iPad models, use CLLocationManager as a heuristic
        // Wi-Fi-only iPads can still get approximate location via Wi-Fi,
        // but lack the precision needed for Geospatial AR.
        // We conservatively assume GPS is available for Cellular iPads.
        return CLLocationManager.locationServicesEnabled()
    }

    /// Get the hardware model identifier (e.g., "iPad15,3", "iPhone16,2").
    private static func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}
