import UIKit

@main
@MainActor
final class DocumentCaptureExampleApp: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
    configuration.delegateClass = DocumentCaptureExampleScene.self
    return configuration
  }
}

@MainActor
final class DocumentCaptureExampleScene: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private weak var controller: DocumentCaptureExampleController?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let controller = DocumentCaptureExampleController()
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UINavigationController(rootViewController: controller)
    window.makeKeyAndVisible()
    self.controller = controller
    self.window = window
  }

  func sceneWillResignActive(_ scene: UIScene) { controller?.suspendCapture() }
  func sceneDidBecomeActive(_ scene: UIScene) { controller?.resumeCapture() }
}
