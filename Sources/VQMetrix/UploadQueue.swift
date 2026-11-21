import Foundation

package struct UploadJob: Codable, Sendable, Identifiable {
    package let id: UUID
    package let digest: String
    package let date: Date
    package var status: String
    package var detail: String?
    package var directory: URL
    package var evaluationModel: VMAFModel? = nil
}

package actor UploadQueue {
    package let root: URL
    private let results: URL
    private var jobs: [UploadJob] = []
    private var processing = false
    package init(root: URL? = nil, results: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VQMetrix")
        self.root = root ?? support.appendingPathComponent("Uploads")
        self.results = results ?? support.appendingPathComponent("Results")
        if let directories = try? FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
            for directory in directories {
                if var job = try? JSONDecoder().decode(UploadJob.self, from: Data(contentsOf: directory.appendingPathComponent("job.json"))) {
                    job.directory = directory
                    if job.status == "Evaluating" { job.status = "Queued" }
    jobs.append(job)
} else if UUID(uuidString: directory.lastPathComponent) != nil {
    // Interrupted pre-acceptance staging must not permanently reserve a run ID.
    try? FileManager.default.moveItem(at: directory, to: self.root.appendingPathComponent("interrupted-\(UUID().uuidString)"))
                }
            }
        }
    }
    package func list() -> [UploadJob] { jobs.sorted { $0.date > $1.date } }
    package func resume() { next() }
    package func accept(file: URL, runID: UUID) throws -> UploadJob {
        defer { try? FileManager.default.removeItem(at: file) }
        let digest = try UploadPackage.digest(file)
        if let existing = jobs.first(where: { $0.id == runID }) {
            guard existing.digest == digest else { throw UploadHTTPError(code: 409, message: "Run ID already exists with different data") }
            return existing
        }
        guard jobs.filter({ ["Queued", "Evaluating"].contains($0.status) }).count < 8 else {
            throw UploadHTTPError(code: 503, message: "Evaluation queue is full")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(runID.uuidString.lowercased())
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw QualityError("Upload directory already exists") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent("upload.zip"))
            _ = try UploadPackage.extract(directory.appendingPathComponent("upload.zip"), to: directory.appendingPathComponent("payload"), runID: runID)
            let job = UploadJob(id: runID, digest: digest, date: Date(), status: "Queued", detail: nil, directory: directory, evaluationModel: VMAFModel(rawValue: UserDefaults.standard.string(forKey: "vmafEvaluationModel") ?? "") ?? .v1)
            try save(job)
            jobs.append(job)
            next()
            return job
        } catch {
            // Preserve invalid packages separately for diagnostics, without reserving their run ID.
            let rejected = root.appendingPathComponent("rejected-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: directory, to: rejected)
            try? String(describing: error).write(to: rejected.appendingPathComponent("validation-error.txt"), atomically: true, encoding: .utf8)
            throw error
        }
    }
    private func save(_ job: UploadJob) throws {
        try JSONEncoder().encode(job).write(to: job.directory.appendingPathComponent("job.json"), options: .atomic)
    }
    private func next() {
        guard !processing, let index = jobs.firstIndex(where: { $0.status == "Queued" }) else { return }
        processing = true
        jobs[index].status = "Evaluating"
        let job = jobs[index]
        try? save(job)
        let results = results
        Task.detached(priority: .utility) {
            var failure: String?
            do {
                let payload = job.directory.appendingPathComponent("payload")
                let manifest = try JSONDecoder().decode(CaptureManifest.self, from: Data(contentsOf: payload.appendingPathComponent("manifest.json")))
                let output = results.appendingPathComponent("upload-\(job.id.uuidString.lowercased())")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try await UploadEvaluation.evaluate(manifest: manifest, payload: payload, output: output, model: job.evaluationModel ?? .legacy)
            } catch { failure = String(describing: error) }
            await self.completed(id: job.id, failure: failure)
        }
    }
    private func completed(id: UUID, failure: String?) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].status = failure == nil ? "Completed" : "Failed"
            jobs[index].detail = failure
            try? save(jobs[index])
        }
        processing = false
        next()
    }
}

struct UploadHTTPError: Error { let code: Int; let message: String }
