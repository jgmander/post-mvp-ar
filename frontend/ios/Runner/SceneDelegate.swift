import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        
        // The FlutterSceneDelegate automatically creates the UIWindow and root FlutterViewController.
        // We safely extract it here, completely avoiding the didFinishLaunching nil-crash.
        if let controller = window?.rootViewController as? FlutterViewController,
           let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.setupARKitChannel(controller: controller)
            print("DEBUG: [Post] SceneDelegate successfully bound ARKit MethodChannel to FlutterViewController")
        }
    }
}
