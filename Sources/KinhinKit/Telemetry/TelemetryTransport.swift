import Foundation
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk
import PersistenceExporter
import Security

/// How an `OTelBackend`'s OTLP exporters reach the collector beyond the endpoint itself: the trust
/// anchors for HTTPS (`ca_file`) and the on-disk queue (`persist`). One per backend; `invalidate()`
/// releases the URLSession it may hold.
final class TelemetryTransport: @unchecked Sendable {
    /// Largest the queue of one signal grows on disk; the oldest files go first.
    static let maxQueueBytes: UInt64 = 32 * 1_024 * 1_024
    /// Queued data older than this is dropped unsent (a day-old span is no longer worth a dashboard's attention).
    static let maxQueueAge: TimeInterval = 12 * 60 * 60

    let httpClient: any HTTPClient
    /// Whether exporters keep failed batches on disk, in which case the HTTP exporter must not also requeue them in memory.
    let persist: Bool
    private let session: URLSession?
    private let queueRoot: URL

    init(settings: TelemetrySettings, queueRoot: URL) throws {
        persist = settings.persist
        self.queueRoot = queueRoot
        if let caFile = settings.caFile {
            let anchors: [SecCertificate]
            do {
                anchors = try TelemetryCABundle.load(path: caFile)
            } catch {
                throw TelemetryError.badCAFile((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            let configuration = URLSessionConfiguration.ephemeral
            // Same as the SDK's default client: no cache, so request bodies are not retained.
            configuration.urlCache = nil
            let session = URLSession(
                configuration: configuration, delegate: TelemetryTrustDelegate(anchors: anchors), delegateQueue: nil)
            self.session = session
            httpClient = BaseHTTPClient(session: session)
        } else {
            session = nil
            httpClient = BaseHTTPClient()
        }
    }

    func invalidate() {
        session?.finishTasksAndInvalidate()
    }

    // MARK: - Persistence

    /// The queue's tuning: a hard size cap and age limit, flushed to disk as it arrives.
    static let preset = PersistencePerformancePreset(
        maxFileSize: 2 * 1_024 * 1_024, maxDirectorySize: maxQueueBytes, maxFileAgeForWrite: 4.75,
        minFileAgeForRead: 5.25, maxFileAgeForRead: maxQueueAge, maxObjectsInFile: 500, maxObjectSize: 256 * 1_024,
        synchronousWrite: false, initialExportDelay: 5, defaultExportDelay: 5, minExportDelay: 1, maxExportDelay: 60,
        exportDelayChangeRate: 0.1)

    /// The queue directory of one signal, created owner-only. Spans and logs carry job and repository names.
    private func queueDirectory(_ name: String) throws -> URL {
        let directory = queueRoot.appendingPathComponent(name, isDirectory: true)
        do {
            try Paths.createPrivateDirectory(directory)
        } catch {
            throw TelemetryError.queueUnavailable(directory.path, error.localizedDescription)
        }
        return directory
    }

    func wrap(_ exporter: any SpanExporter) throws -> any SpanExporter {
        guard persist else { return exporter }
        return PersistenceSpanExporterDecorator(
            spanExporter: exporter, storageURL: try queueDirectory("traces"), performancePreset: Self.preset)
    }

    func wrap(_ exporter: any LogRecordExporter) throws -> any LogRecordExporter {
        guard persist else { return exporter }
        return PersistenceLogExporterDecorator(
            logRecordExporter: exporter, storageURL: try queueDirectory("logs"), performancePreset: Self.preset)
    }
}
