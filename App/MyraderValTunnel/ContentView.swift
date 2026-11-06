import SwiftUI
import NetworkExtension

/// 容器 App：把 SOCKS5 出口写入 NETunnelProviderManager 配置，并拉起 Packet Tunnel 扩展。
struct ContentView: View {
    // MARK: - 配置项（按需修改默认值）
    @State private var server: String = "proxy.example.com"
    @State private var port: String = "1080"
    @State private var username: String = ""
    @State private var password: String = ""

    @State private var status: String = "未配置"
    @State private var message: String = ""
    @State private var statusObserver: NSObjectProtocol?

    /// 缓存当前 VPN 配置对象。NETunnelProviderManager 是引用类型，
    /// 用 @State 持有以便在多个回调间复用同一实例（不需要它驱动视图刷新）。
    @State private var tunnelManager: NETunnelProviderManager?

    /// 必须与 Extension target 的 PRODUCT_BUNDLE_IDENTIFIER 完全一致
    private let extensionBundleId = "com.myraderval.MyraderValTunnel.extension"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("SOCKS5 出口")) {
                    TextField("服务器地址（不要带端口）", text: $server)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("用户名（可选）", text: $username)
                        .autocapitalization(.none)
                    SecureField("密码（可选）", text: $password)
                }
                Section(header: Text("状态")) {
                    HStack {
                        Text("连接")
                        Spacer()
                        Text(status).foregroundColor(.secondary)
                    }
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundColor(.red)
                    }
                }
                Section {
                    Button(action: toggleVPN) {
                        HStack {
                            Spacer()
                            Text(status == "已连接" ? "断开" : "连接")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("MyraderValTunnel")
            .onAppear(perform: setup)
            .onDisappear(perform: teardown)
        }
    }

    // MARK: - 配置加载

    private func setup() {
        // ContentView 是值类型（struct），不能对 self 使用 weak / unowned。
        // 闭包捕获的是 self 的值拷贝；@State 内部为引用盒，写入仍会反映到视图，
        // 且值类型不会与闭包形成循环引用。观察者本身已在 teardown() 中移除。
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { _ in
            self.refreshStatus()
        }
        loadTunnelManager { manager in
            self.tunnelManager = manager
            self.refreshStatus()
        }
    }

    /// 自定义 Packet Tunnel 必须用 NETunnelProviderManager 配置。
    /// NEVPNManager.shared() 是 Personal VPN（IPSec / IKEv2）专用，
    /// 给它配 NETunnelProviderProtocol 会报
    /// "Missing protocol or protocol has invalid type"（NEVPNErrorConfigurationInvalid）。
    /// 参��� Apple DTS：NEVPNManager 直接用于 Personal VPN，
    /// 其子类 NETunnelProviderManager 才用于 NE tunnel provider。
    private func loadTunnelManager(completion: @escaping (NETunnelProviderManager) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                NSLog("[MyraderValTunnel] loadAllFromPreferences: \(error)")
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            manager.loadFromPreferences { loadError in
                if let loadError = loadError {
                    NSLog("[MyraderValTunnel] loadFromPreferences: \(loadError)")
                }
                DispatchQueue.main.async {
                    completion(manager)
                }
            }
        }
    }

    private func teardown() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        statusObserver = nil
    }

    private func refreshStatus() {
        guard let manager = tunnelManager else {
            status = "未配置"
            return
        }
        switch manager.connection.status {
        case .connected:     status = "已连接"
        case .connecting:    status = "连接中"
        case .disconnecting: status = "断开中"
        case .disconnected:  status = "未连接"
        case .reasserting:   status = "重连中"
        case .invalid:       status = "未配置"
        @unknown default:    status = "未知"
        }
    }

    // MARK: - SOCKS5 参数

    /// 容错：若把 "host:port" 一起填进地址栏，只取冒号前的主机部分，端口仍以端口栏为准。
    private var effectiveHost: String {
        let raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = raw.range(of: #":\d+$"#, options: .regularExpression) {
            return String(raw[..<r.lowerBound])
        }
        return raw
    }

    private var effectivePort: Int {
        Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1080
    }

    // MARK: - VPN 控制

    private func toggleVPN() {
        guard let manager = tunnelManager else {
            loadTunnelManager { loaded in
                self.tunnelManager = loaded
                self.refreshStatus()
                self.performToggle(manager: loaded)
            }
            return
        }
        performToggle(manager: manager)
    }

    private func performToggle(manager: NETunnelProviderManager) {
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            manager.connection.stopVPNTunnel()
        default:
            saveAndConnect(manager: manager)
        }
    }

    private func saveAndConnect(manager: NETunnelProviderManager) {
        let host = effectiveHost
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleId
        proto.serverAddress = host
        proto.providerConfiguration = [
            "host": host,
            "port": NSNumber(value: effectivePort),
            "username": username,
            "password": password,
            "tunnelIPv4": "198.18.0.1",
            "mtu": NSNumber(value: 1500)
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "MyraderValTunnel"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false

        manager.saveToPreferences { saveError in
            if let saveError = saveError {
                DispatchQueue.main.async {
                    self.message = "保存失败：\(saveError.localizedDescription)"
                }
                return
            }
            // 重新加载一次，消除「配置尚未生效」导致的 startVPNTunnel 竞态
            manager.loadFromPreferences { loadError in
                if let loadError = loadError {
                    DispatchQueue.main.async {
                        self.message = "重载失败：\(loadError.localizedDescription)"
                    }
                    return
                }
                do {
                    try manager.connection.startVPNTunnel()
                    DispatchQueue.main.async {
                        self.message = ""
                        self.refreshStatus()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.message = "启动失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
