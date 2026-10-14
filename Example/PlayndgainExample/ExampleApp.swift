import Playndgain
import UIKit

/// A test harness, not an integration example to copy. It signs on the
/// device with a secret typed into a field, which a real app must never do:
/// a real app asks its own server for the signature. See README.md.
///
/// Launch arguments pre-fill the form for scripted runs:
/// `-base http://localhost:8765 -userid USER_1 -lang ar -autoshow 1`
final class ExampleViewController: UIViewController, PlayndgainDelegate {
    private let log = UITextView()
    private var fields: [String: UITextField] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let d = UserDefaults.standard

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        for (key, placeholder, value) in [
            ("base", "Base URL", d.string(forKey: "base") ?? "http://localhost:8000"),
            ("appid", "App ID", d.string(forKey: "appid") ?? "10000"),
            ("userid", "User ID", d.string(forKey: "userid") ?? "USER_1"),
            ("secret", "Secret: local testing only, never ship this", ""),
            ("lang", "Language (en / ar, blank = device)", d.string(forKey: "lang") ?? ""),
            ("sub1", "sub1 (optional)", "sample"),
            ("balance", "Balance shown in the header (optional)", d.string(forKey: "balance") ?? ""),
        ] {
            let f = UITextField()
            f.placeholder = placeholder
            f.text = value
            f.borderStyle = .roundedRect
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.isSecureTextEntry = key == "secret"
            fields[key] = f
            stack.addArrangedSubview(f)
        }

        let show = UIButton(type: .system)
        show.setTitle("Show", for: .normal)
        show.addTarget(self, action: #selector(showWall), for: .touchUpInside)
        stack.addArrangedSubview(show)

        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        log.heightAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(log)

        Playndgain.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if UserDefaults.standard.string(forKey: "autoshow") == "1", presentedViewController == nil, log.text.isEmpty {
            showWall()
        }
    }

    @objc private func showWall() {
        let text = { (k: String) in self.fields[k]?.text ?? "" }
        let base = text("base").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let baseURL = URL(string: base), baseURL.scheme != nil, baseURL.host != nil else {
            write("enter a base URL such as http://localhost:8000")
            return
        }
        Playndgain.initialize(appId: text("appid"), config: PlayndgainConfig(baseURL: baseURL, debugLogging: true))
        let secret = text("secret")
        Playndgain.setUser(text("userid")) { appId, userId, completion in
            completion(.success(secret.isEmpty ? "" : Self.sha256(appId + userId + secret)))
        }
        Playndgain.show(from: self, options: PlayndgainOptions(
            language: text("lang").isEmpty ? nil : text("lang"),
            balance: text("balance").isEmpty ? nil : text("balance"),
            subIds: text("sub1").isEmpty ? [] : [text("sub1")]
        ))
    }

    func playndgainDidOpen() { write("didOpen") }
    func playndgainDidClose() { write("didClose") }
    func playndgainRewardCheck() { write("rewardCheck") }
    func playndgainDidFail(_ error: PlayndgainError) { write("didFail \(error)") }

    private func write(_ event: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.text += "\(f.string(from: Date()))  \(event)\n"
        NSLog("PlayndgainExample: %@", event)
    }

    private static func sha256(_ s: String) -> String {
        // CryptoKit, iOS 13+.
        import_sha256(s)
    }
}

import CryptoKit

private func import_sha256(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
}

/// Scene lifecycle: current iOS stops an app built with the latest SDK that
/// still sets up its window in the app delegate.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ExampleViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
