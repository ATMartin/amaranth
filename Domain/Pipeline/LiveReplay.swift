public import Foundation

/// T20 exchange format between `amaranth-bench live-suite` (writes the spec, aggregates the results) and the app's
/// `--self-test live-replay`: excerpts of recorded meetings are replayed **in real time** through the real capture path
/// while live text runs through the real XPC worker (with incremental processing, as in the app), to measure live text
/// delay on real recordings (gate G4). Results hold metrics only, never text.
///
/// Per item the app writes `<outputDirectory>/<item id>/result.json` (`LiveReplay.Result`) and `live-latency.json`.
public enum LiveReplay {
    public struct Spec: Codable, Sendable {
        public var items: [Item]
        public var outputDirectory: String
        /// Live text settings under test.
        public var tickSeconds: Double
        public var perSource: Bool
        /// Run incremental processing during the replay, as the app does by default ("Process while recording").
        public var incremental: Bool
        public init(items: [Item], outputDirectory: String, tickSeconds: Double, perSource: Bool, incremental: Bool) {
            self.items = items; self.outputDirectory = outputDirectory; self.tickSeconds = tickSeconds
            self.perSource = perSource; self.incremental = incremental
        }
    }

    public struct Item: Codable, Sendable {
        public var id: String
        /// A private copy of an Amaranth library (never the user's own) and a meeting in it.
        public var library: String
        public var meetingID: String
        /// Excerpt start and length in the meeting's session time.
        public var start: Double
        public var seconds: Double
        public init(id: String, library: String, meetingID: String, start: Double, seconds: Double) {
            self.id = id; self.library = library; self.meetingID = meetingID; self.start = start; self.seconds = seconds
        }
    }

    public struct Result: Codable, Sendable {
        public struct Source: Codable, Sendable {
            public var source: String
            public var samples: Int
            public var medianSeconds: Double?
            public var p95Seconds: Double?
            /// Live words versus the meeting's final transcript over the excerpt (word error rate, 0–1): agreement,
            /// not accuracy (the final transcript is not a human reference).
            public var disagreementWithFinal: Double?
            public var finalWords: Int
            public var liveWords: Int
            public init(source: String, samples: Int, medianSeconds: Double?, p95Seconds: Double?, disagreementWithFinal: Double?, finalWords: Int, liveWords: Int) {
                self.source = source; self.samples = samples; self.medianSeconds = medianSeconds; self.p95Seconds = p95Seconds
                self.disagreementWithFinal = disagreementWithFinal; self.finalWords = finalWords; self.liveWords = liveWords
            }
        }
        public var id: String
        public var completed: Bool
        public var failure: String?
        public var audioSeconds: Double
        public var tickSeconds: Double
        public var perSource: Bool
        public var incremental: Bool
        public var requests: Int
        /// Every delay sample in seconds (pooled across items by the bench), and its median/p95.
        public var latencies: [Double]
        public var medianSeconds: Double?
        public var p95Seconds: Double?
        /// Medians of the breakdown: until the segment was saved, waiting to be sent, worker round trip.
        public var medianUnsaved: Double?
        public var medianWaiting: Double?
        public var medianWorker: Double?
        public var p95Waiting: Double?
        public var p95Worker: Double?
        public var sources: [Source]
        public var missingAudioEvents: Int
        public var ringOverruns: Int
        public var appPeakMiB: Double
        public var workerPeakMiB: Double
        public init(id: String, completed: Bool, failure: String? = nil, audioSeconds: Double, tickSeconds: Double, perSource: Bool, incremental: Bool,
                    requests: Int = 0, latencies: [Double] = [], sources: [Source] = [], missingAudioEvents: Int = 0, ringOverruns: Int = 0,
                    appPeakMiB: Double = 0, workerPeakMiB: Double = 0) {
            self.id = id; self.completed = completed; self.failure = failure; self.audioSeconds = audioSeconds; self.tickSeconds = tickSeconds
            self.perSource = perSource; self.incremental = incremental; self.requests = requests; self.latencies = latencies; self.sources = sources
            self.missingAudioEvents = missingAudioEvents; self.ringOverruns = ringOverruns; self.appPeakMiB = appPeakMiB; self.workerPeakMiB = workerPeakMiB
        }
    }
}
