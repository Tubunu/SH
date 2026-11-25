import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()

    let cookieChannel = FlutterMethodChannel(
      name: "com.hengye.share/cookies",
      binaryMessenger: messenger
    )
    cookieChannel.setMethodCallHandler { call, result in
      let store = WKWebsiteDataStore.default().httpCookieStore
      switch call.method {
      case "getCookies":
        store.getAllCookies { cookies in
          var merged: [String: String] = [:]
          for cookie in cookies {
            let domain = cookie.domain.lowercased()
            if domain.hasSuffix("weibo.com")
              || domain.hasSuffix("weibo.cn")
              || domain.hasSuffix("sina.com.cn")
              || domain.hasSuffix("sina.cn")
            {
              merged[cookie.name] = cookie.value
            }
          }
          let header = merged
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
          result(header)
        }
      case "clearCookies":
        store.getAllCookies { cookies in
          let group = DispatchGroup()
          for cookie in cookies {
            let domain = cookie.domain.lowercased()
            if domain.hasSuffix("weibo.com")
              || domain.hasSuffix("weibo.cn")
              || domain.hasSuffix("sina.com.cn")
              || domain.hasSuffix("sina.cn")
            {
              group.enter()
              store.delete(cookie) {
                group.leave()
              }
            }
          }
          group.notify(queue: .main) {
            result(true)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let platformChannel = FlutterMethodChannel(
      name: "com.hengye.share/platform",
      binaryMessenger: messenger
    )
    platformChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "setLauncherIcon":
        guard #available(iOS 10.3, *), UIApplication.shared.supportsAlternateIcons else {
          result(false)
          return
        }
        let args = call.arguments as? [String: Any]
        let alias = (args?["alias"] as? String) ?? "Launcher"
        let iconName: String? = (alias == "Launcher") ? nil : alias
        UIApplication.shared.setAlternateIconName(iconName) { error in
          result(error == nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
