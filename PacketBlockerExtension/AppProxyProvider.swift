import NetworkExtension
import Network

class AppProxyProvider: NEAppProxyProvider {

    private var isLagEnabled = false
    private let queue = DispatchQueue(label: "com.fakelag.proxy", qos: .userInitiated)

    override func startProxy(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        isLagEnabled = false
        NSLog("[FakeLag] Proxy started. Lag = OFF")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isLagEnabled = false
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let cmd = String(data: messageData, encoding: .utf8) {
            isLagEnabled = (cmd == "enable")
            NSLog("[FakeLag] Lag = \(isLagEnabled ? "ON" : "OFF")")
        }
        completionHandler?(Data("ok".utf8))
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let udpFlow = flow as? NEAppProxyUDPFlow {
            handleUDPFlow(udpFlow)
            return true
        }
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            handleTCPFlow(tcpFlow)
            return true
        }
        return false
    }

    // MARK: - UDP (Game traffic - delay + drop)

    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) {
        guard let remoteEndpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            flow.closeReadWithError(nil)
            return
        }

        let port = UInt16(remoteEndpoint.port) ?? 0
        let connection = NWConnection(
            to: .hostPort(host: .name(remoteEndpoint.hostname, nil), port: .integer(port)),
            using: .udp
        )

        connection.stateUpdateHandler = { state in
            if case .failed = state {
                flow.closeReadWithError(nil)
            }
        }

        connection.start(queue: queue)

        // App → Remote (with lag)
        forwardFromApp(flow: flow, to: connection)

        // Remote → App (no lag)
        forwardFromRemote(connection: connection, to: flow)
    }

    private func forwardFromApp(flow: NEAppProxyUDPFlow, to connection: NWConnection) {
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self = self, error == nil else {
                connection.cancel()
                return
            }

            guard let datagrams = datagrams, !datagrams.isEmpty else {
                self.forwardFromApp(flow: flow, to: connection)
                return
            }

            for datagram in datagrams {
                if self.isLagEnabled {
                    // Drop 15%
                    if Int.random(in: 0..<100) < 15 {
                        continue
                    }
                    // Delay 300ms
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) {
                        connection.send(content: datagram, completion: .contentProcessed { _ in })
                    }
                } else {
                    connection.send(content: datagram, completion: .contentProcessed { _ in })
                }
            }

            self.forwardFromApp(flow: flow, to: connection)
        }
    }

    private func forwardFromRemote(connection: NWConnection, to flow: NEAppProxyUDPFlow) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self = self, error == nil, let content = content else {
                flow.closeWriteWithError(nil)
                return
            }

            flow.writeDatagrams([content], sentBy: [flow.remoteEndpoint]) { error in
                // continue
            }

            self.forwardFromRemote(connection: connection, to: flow)
        }
    }

    // MARK: - TCP (Forward ngay, không delay)

    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) {
        guard let remoteEndpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            flow.closeReadWithError(nil)
            return
        }

        let port = UInt16(remoteEndpoint.port) ?? 0
        let connection = NWConnection(
            to: .hostPort(host: .name(remoteEndpoint.hostname, nil), port: .integer(port)),
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            if case .failed = state {
                flow.closeReadWithError(nil)
            }
        }

        connection.start(queue: queue)

        // App → Remote
        flow.readData { [weak self] data, error in
            guard let data = data, error == nil else {
                connection.cancel()
                return
            }
            connection.send(content: data, completion: .contentProcessed { _ in })
            self?.forwardTCPFromApp(flow: flow, connection: connection)
        }

        // Remote → App
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] content, _, isComplete, error in
            guard let content = content, error == nil else {
                flow.closeWriteWithError(nil)
                return
            }
            flow.write(content) { _ in }
            if !isComplete {
                self?.forwardTCPFromRemote(connection: connection, flow: flow)
            }
        }
    }

    private func forwardTCPFromApp(flow: NEAppProxyTCPFlow, connection: NWConnection) {
        flow.readData { [weak self] data, error in
            guard let data = data, error == nil else {
                connection.cancel()
                return
            }
            connection.send(content: data, completion: .contentProcessed { _ in })
            self?.forwardTCPFromApp(flow: flow, connection: connection)
        }
    }

    private func forwardTCPFromRemote(connection: NWConnection, flow: NEAppProxyTCPFlow) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] content, _, isComplete, error in
            guard let content = content, error == nil else {
                flow.closeWriteWithError(nil)
                return
            }
            flow.write(content) { _ in }
            if !isComplete {
                self?.forwardTCPFromRemote(connection: connection, flow: flow)
            }
        }
    }
}
