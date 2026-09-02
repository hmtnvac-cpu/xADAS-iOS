import Foundation
import Network

final class RTSPProbe: ObservableObject {
    @Published private(set) var status = "70MAI IDLE"
    @Published private(set) var isReachable = false

    private let queue = DispatchQueue(label: "xadas.rtsp.probe")
    private var connection: NWConnection?

    func probe(urlString: String) {
        stop()
        guard let url = URL(string: urlString),
              let hostName = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554)) else {
            status = "70MAI URL INVALID"
            return
        }

        DispatchQueue.main.async {
            self.status = "70MAI CONNECTING"
            self.isReachable = false
        }

        let connection = NWConnection(host: NWEndpoint.Host(hostName), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendOptions(on: connection, urlString: urlString)
            case .failed(let error):
                DispatchQueue.main.async {
                    self.status = "70MAI OFFLINE • \(error.localizedDescription)"
                    self.isReachable = false
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }

    private func sendOptions(on connection: NWConnection?, urlString: String) {
        guard let connection else { return }
        let request = "OPTIONS \(urlString) RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: xADAS-iOS/0.7\r\n\r\n"
        connection.send(content: request.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.status = "70MAI RTSP ERROR • \(error.localizedDescription)"
                    self?.isReachable = false
                }
                return
            }
            self?.receiveResponse(from: connection)
        })
    }

    private func receiveResponse(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let response = String(data: data, encoding: .utf8), response.contains("RTSP/1.0 200") {
                DispatchQueue.main.async {
                    self.status = "70MAI RTSP READY"
                    self.isReachable = true
                }
            } else {
                DispatchQueue.main.async {
                    self.status = error == nil ? "70MAI RTSP NO RESPONSE" : "70MAI RTSP ERROR"
                    self.isReachable = false
                }
            }
            connection.cancel()
        }
    }
}
