import SwiftUI
import NetworkExtension

/// 容器 App：把 SOCKS5 出口写入 NEVPNManager 配置，并拉起 Packet Tunnel 扩展。
struct ContentView: View {
    // MARK: - 配置项（按需修改默认值）
    @State private var server: String = "proxy.example.com"
    @State private var port: String = "1080"
    @State private var username: String = ""
    @State private var password: String = ""

    @State private var status: String = "未连接"
    @State private var message: String = ""
    @State private var statusObserver: NSObjectProtocol?

    /// 必须与 Extension target 的 PRODUCT_BUNDLE_IDENTIFIER 完全一致
    private let extensionBundleId = "com.myraderval.MyraderValTunnel.extension"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("SOCKS5 出口")) {
                    TextField("服务器地址", text: $server)
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

    // MARK: - 状态监听

    private func setup() {
        refreshStatus()
        // 用 [weak self] 避免闭包内显式 self 的编译要求与循环引用
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func teardown() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        statusObserver = nil
    }

    private func refreshStatus() {
        switch NEVPNManager.shared().connection.status {
        case .connected:    status = "已连接"
        case .connecting:   status = "连接中"
        case .disconnecting: status = "断开中"
        case .disconnected: status = "未连接"
        case .reasserting:  status = "重连中"
        case .invalid:      status = "未配置"
        @unknown default:   status = "未知"
        }
    }

    // MARK: - VPN 控制

    private func toggleVPN() {
        let manager = NEVPNManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                NSLog("[MyraderValTunnel] loadFromPreferences: \(error)")
                // 首次运行时可能没有配置，继续写入即可
            }
            let current = manager.connection.status
            if current == .connected || current == .connecting {
                manager.connection.stopVPNTunnel()
            } else {
                self.saveAndConnect(manager: manager)
            }
        }
    }

    private func saveAndConnect(manager: NEVPNManager) {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleId
        proto.serverAddress = server
        proto.providerConfiguration = [
            "host": server,
            "port": NSNumber(value: Int(port) ?? 1080),
            "username": username,
            "password": password,
            "tunnelIPv4": "198.18.0.1",
            "mtu": NSNumber(value: 1500)
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "MyraderValTunnel"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false

        manager.saveToPreferences { [weak self] saveError in
            guard let self = self else { return }
            if let saveError = saveError {
                self.message = "保存失败：\(saveError.localizedDescription)"
                return
            }
            // 重新加载一次，消除「配置尚未生效」导致的 startVPNTunnel 竞态
            manager.loadFromPreferences { loadError in
                if let loadError = loadError {
                    self.message = "重载失败：\(loadError.localizedDescription)"
                    return
                }
                do {
                    try manager.connection.startVPNTunnel()
                    self.message = ""
                } catch {
                    self.message = "启动失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
