import UIKit
import NetworkExtension
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    
    private var tProxyService: TProxyService?
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        
        // Initialize TProxyService when the app starts
        self.tProxyService = TProxyService()
        
        setupFlutterMethodChannel()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func setupFlutterMethodChannel() {
        let controller = window?.rootViewController as! FlutterViewController
        let channel = FlutterMethodChannel(name: "com.github.anyportal.anyportal", binaryMessenger: controller.binaryMessenger)
        
        channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            if call.method == "startAll" {
                self.tProxyService?.startAll()
                result(nil)
            } else if call.method == "stopAll" {
                self.tProxyService?.stopAll()
                result(nil)
            } else if call.method == "isTProxyRunning" {
                let isRunning = self.isTProxyRunning()
                result(isRunning)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    var _isTProxyRunning: Bool = false
    
    private func updateisTProxyRunning(value: Bool) {
        _isTProxyRunning = value
    }

    // Check if the TProxyService is running
    private func isTProxyRunning() -> Bool {
        self.tProxyService?.isServiceRunning(completion: updateisTProxyRunning)
        return _isTProxyRunning
    }
}
