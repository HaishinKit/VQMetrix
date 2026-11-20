import Foundation
import Network
import SystemConfiguration

struct UploadRequest {
    let length: Int64
    let runID: UUID
    static func parse(_ data: Data, token: String) throws -> Self {
        guard let text = String(data: data, encoding: .utf8) else { throw UploadHTTPError(code: 400, message: "Invalid headers") }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "POST /api/v1/runs HTTP/1.1" else { throw UploadHTTPError(code: 404, message: "Use POST /api/v1/runs") }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw UploadHTTPError(code: 400, message: "Invalid header") }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw UploadHTTPError(code: 400, message: "Duplicate header") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let expected = Array("Bearer \(token)".utf8), supplied = Array((headers["authorization"] ?? "").utf8)
        guard expected.count == supplied.count, zip(expected,supplied).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw UploadHTTPError(code: 401, message: "Invalid receiver token")
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil,
              headers["content-type"] == "application/zip", headers["x-vqmetrix-protocol"] == "1",
              let rawLength = headers["content-length"], rawLength.allSatisfy(\.isNumber), let length = Int64(rawLength),
              let id = headers["idempotency-key"].flatMap(UUID.init(uuidString:)) else { throw UploadHTTPError(code: 400, message: "Missing or invalid upload headers") }
        guard length > 0, length <= UploadPackage.maxUpload else { throw UploadHTTPError(code: 413, message: "Upload limit is 512 MiB") }
        return Self(length: length, runID: id)
    }
}

struct UploadAuthLimiter {
    private var failures = 0
    private var firstFailure: Date?
    private var blockedUntil: Date?
    mutating func parse(_ data: Data, token: String, now: Date = Date()) throws -> UploadRequest {
        if let blockedUntil, now < blockedUntil { throw UploadHTTPError(code: 429, message: "Too many incorrect codes. Wait one minute.") }
        if blockedUntil != nil || firstFailure.map({ now.timeIntervalSince($0) >= 60 }) == true {
            failures = 0; firstFailure = nil; blockedUntil = nil
        }
        do { return try UploadRequest.parse(data, token: token) }
        catch {
            if (error as? UploadHTTPError)?.code == 401 {
                if firstFailure == nil { firstFailure = now }
                failures += 1
                if failures >= 5 { blockedUntil = now.addingTimeInterval(60) }
            }
            throw error
        }
    }
}

package final class UploadServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VQMetrix.UploadHTTP")
    private let store: UploadQueue
    private let token: String
    private let listener: NWListener
    private var clients: [UUID: UploadConnection] = [:]
    private var progress: [UUID: (Int64, Int64)] = [:]
    private var authLimiter = UploadAuthLimiter()
    package let hostname: String
    package init(port: UInt16 = 8787, token: String, store: UploadQueue) throws {
        guard !token.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else { throw QualityError("Invalid receiver settings") }
        self.token = token; self.store = store
        hostname = (SCDynamicStoreCopyLocalHostName(nil) as String? ?? "VQMetrix") + ".local"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        listener = try NWListener(using: parameters, on: endpointPort)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "VQMetrix", type: "_vqmetrix._tcp", txtRecord: NWTXTRecord(["protocol":"1", "scheme":"http", "host":hostname]))
    }
    package func start(advertisement: @escaping @Sendable (Bool) -> Void = { _ in }, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }, state: @escaping @Sendable (String) -> Void) {
        listener.serviceRegistrationUpdateHandler = { change in
            switch change { case .add: advertisement(true); case .remove: advertisement(false); @unknown default: break }
        }
        listener.stateUpdateHandler = { status in
            switch status {
            case .ready: state("Listening")
            case .failed(let error): state(String(describing: error))
            case .cancelled: state("Stopped")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.clients.count < 4, Self.local(connection.endpoint) else { connection.cancel(); return }
            let id = UUID()
            let client = UploadConnection(connection: connection, queue: self.queue, store: self.store, authorize: { [weak self] data in
                guard let self else { throw UploadHTTPError(code: 503, message: "Receiver stopped") }
                return try self.authLimiter.parse(data, token: self.token)
            }, progress: { [weak self] received, total in
                guard let self else { return }
                self.progress[id] = (received,total)
                progress(self.progress.values.reduce(0) { $0 + $1.0 }, self.progress.values.reduce(0) { $0 + $1.1 })
            }) { [weak self] in
                guard let self else { return }
                self.clients.removeValue(forKey: id); self.progress.removeValue(forKey: id)
                progress(self.progress.values.reduce(0) { $0 + $1.0 }, self.progress.values.reduce(0) { $0 + $1.1 })
            }
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: queue)
        Task { await store.resume() }
    }
    package func stop() {
        queue.async { [self] in
            listener.cancel()
            let connections = Array(clients.values)
            for client in connections { client.close() }
        }
    }
    private static func local(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        func v4(_ bytes: [UInt8]) -> Bool {
            bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254)
        }
        switch host {
        case .ipv4(let address): return v4(Array(address.rawValue))
        case .ipv6(let address):
            let b = Array(address.rawValue)
            return b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80) ||
                (b.prefix(15).allSatisfy { $0 == 0 } && b[15] == 1) ||
                (b.prefix(10).allSatisfy { $0 == 0 } && b[10] == 255 && b[11] == 255 && v4(Array(b.suffix(4))))
        default: return false
        }
    }
}

private final class UploadConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let authorize: @Sendable (Data) throws -> UploadRequest
    private let store: UploadQueue
    private let finished: @Sendable () -> Void
    private let progress: @Sendable (Int64,Int64) -> Void
    private var header = Data()
    private var request: UploadRequest?
    private var received: Int64 = 0
    private var file: URL?
    private var handle: FileHandle?
    private var closed = false
    private var accepting = false
    private var timeout: DispatchWorkItem?
    init(connection: NWConnection, queue: DispatchQueue, store: UploadQueue, authorize: @escaping @Sendable (Data) throws -> UploadRequest, progress: @escaping @Sendable (Int64,Int64) -> Void, finished: @escaping @Sendable () -> Void) {
        self.connection = connection; self.queue = queue; self.authorize = authorize; self.store = store; self.finished = finished; self.progress = progress
    }
    func start() {
        connection.start(queue: queue)
        receive()
    }
    private func receive() {
        timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + 60, execute: timeout)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            guard !closed else { return }
            do {
                if let data {
                    if request == nil {
                        header.append(data)
                        if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                            guard end.upperBound <= 16384 else { throw UploadHTTPError(code: 431, message: "Headers too large") }
                            request = try authorize(header.subdata(in: 0..<end.lowerBound))
                            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VQMetrix-Incoming")
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                            guard capacity > UploadPackage.maxExtracted + (request?.length ?? 0) else { throw UploadHTTPError(code: 507, message: "Not enough storage") }
                            let file = directory.appendingPathComponent(UUID().uuidString + ".zip")
                            self.file = file
                            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                            handle = try FileHandle(forWritingTo: file)
                            let body = header.subdata(in: end.upperBound..<header.count)
                            header.removeAll()
                            try append(body)
                        } else if header.count > 16384 { throw UploadHTTPError(code: 431, message: "Headers too large") }
                    } else { try append(data) }
                }
                if let request, received == request.length, let file {
                    try handle?.close(); handle = nil
                    accepting = true; self.timeout?.cancel()
                    Task {
                        do {
                            let job = try await store.accept(file: file, runID: request.runID)
                            let response = try JSONSerialization.data(withJSONObject: ["jobId": job.id.uuidString.lowercased(), "status": job.status.lowercased()])
                            queue.async { [self] in respond(code: 202, body: response) }
                        } catch {
                            let failure = error as? UploadHTTPError
                            queue.async { [self] in respondError(code: failure?.code ?? 400, message: failure?.message ?? "Package validation failed") }
                        }
                    }
                    return
                }
                if complete || error != nil { close() } else { receive() }
            } catch {
                let failure = error as? UploadHTTPError
                respondError(code: failure?.code ?? 400, message: failure?.message ?? "Upload failed")
            }
        }
    }
    private func append(_ data: Data) throws {
        guard let request, received + Int64(data.count) <= request.length else { throw UploadHTTPError(code: 400, message: "Body exceeds Content-Length") }
        try handle?.write(contentsOf: data); received += Int64(data.count)
        progress(received,request.length)
    }
    private func respondError(code: Int, message: String) {
        respond(code: code, body: (try? JSONSerialization.data(withJSONObject: ["error":message])) ?? Data())
    }
    private func respond(code: Int, body: Data) {
        guard !closed else { return }
        timeout?.cancel()
        var response = Data("HTTP/1.1 \(code) \(code == 202 ? "Accepted" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [self] _ in close() })
    }
    func close() {
        guard !closed else { return }
        closed = true; timeout?.cancel(); try? handle?.close(); handle = nil
        if !accepting, let file { try? FileManager.default.removeItem(at: file) }
        connection.cancel(); finished()
    }
}
