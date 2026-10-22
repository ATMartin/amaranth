public import Foundation

/// T16 perf-suite exchange format between `amaranth-bench perf-suite` (writes the spec, scores the outputs) and the
/// app's `--self-test perf-run` (replays each item through the real capture path, XPC worker and scheduler).
///
/// Per item run the app writes `<outputDirectory>/<item id>/<run>/`: `result.json` (`PerfRun.ItemResult`),
/// `asr.json` and `transcript.json` (`TranscriptRevision`: ASR and final published), `diarization.json`
/// (`[DiarizationResult]`) and `summary.json` (`SummaryRevision`), whichever exist.
public enum PerfRun {
    public struct Spec: Codable, Sendable {
        public var items: [Item]
        public var outputDirectory: String
        /// Capture replay speed (× realtime).
        public var speed: Double
        /// A persistent store of replayed captures. Each audio item is replayed through the capture path once and its
        /// committed meeting reused by later runs: replay timing (host-clock start offset, trailing silence) otherwise
        /// changes the captured audio slightly on every run, and transcripts could never be byte-identical.
        public var captureCache: String?
        public init(items: [Item], outputDirectory: String, speed: Double, captureCache: String? = nil) {
            self.items = items; self.outputDirectory = outputDirectory; self.speed = speed; self.captureCache = captureCache
        }
    }

    public struct Item: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Raw audio replayed as a new recording (system and/or microphone).
            case audio
            /// A meeting recorded in Amaranth: its committed segments are copied from (a copy of) a library.
            case amaranthMeeting
            /// Notes only, from a given attributed transcript (notes quality checks).
            case notesTranscript
        }
        public var id: String
        public var kind: Kind
        public var system: RawAudio?
        public var microphone: RawAudio?
        /// amaranthMeeting: a library directory (already a private copy) and the meeting ID in it.
        public var library: String?
        public var meetingID: String?
        /// notesTranscript: path of a `TranscriptRevision` JSON.
        public var transcript: String?
        public var notes: Bool
        /// Kill the worker before this item (models not resident, fresh process).
        public var coldWorker: Bool
        /// Process an identical copy again right after (warm worker).
        public var repeatWarm: Bool
        public init(id: String, kind: Kind, system: RawAudio? = nil, microphone: RawAudio? = nil, library: String? = nil, meetingID: String? = nil,
                    transcript: String? = nil, notes: Bool, coldWorker: Bool = false, repeatWarm: Bool = false) {
            self.id = id; self.kind = kind; self.system = system; self.microphone = microphone; self.library = library
            self.meetingID = meetingID; self.transcript = transcript; self.notes = notes; self.coldWorker = coldWorker; self.repeatWarm = repeatWarm
        }
    }

    /// Interleaved float32 little-endian samples, no header.
    public struct RawAudio: Codable, Sendable {
        public var path: String
        public var sampleRate: Int
        public var channels: Int
        public init(path: String, sampleRate: Int, channels: Int) { self.path = path; self.sampleRate = sampleRate; self.channels = channels }
    }

    public struct StageResult: Codable, Sendable {
        public var stage: String
        public var state: String
        public var errorCode: String?
        public var scheduler: SchedulerTiming?
        public var worker: StageTiming?
        public init(stage: String, state: String, errorCode: String?, scheduler: SchedulerTiming?, worker: StageTiming?) {
            self.stage = stage; self.state = state; self.errorCode = errorCode; self.scheduler = scheduler; self.worker = worker
        }
    }

    public struct ItemResult: Codable, Sendable {
        public var id: String
        /// "cold", "warm" or "default".
        public var run: String
        public var completed: Bool
        public var failure: String?
        public var audioSeconds: Double
        public var recordWallSeconds: Double?
        public var missingAudioEvents: Int
        /// Stop (pipeline enqueued) → final transcript with speakers / → notes.
        public var stopToTranscriptSeconds: Double?
        public var stopToNotesSeconds: Double?
        public var stages: [StageResult]
        public var peakAppMiB: Double
        public var peakWorkerMiB: Double
        public var workerPIDs: [Int32]
        public var thermalStart: String
        public var thermalEnd: String
        public init(id: String, run: String, completed: Bool, failure: String?, audioSeconds: Double, recordWallSeconds: Double?,
                    missingAudioEvents: Int, stopToTranscriptSeconds: Double?, stopToNotesSeconds: Double?, stages: [StageResult],
                    peakAppMiB: Double, peakWorkerMiB: Double, workerPIDs: [Int32], thermalStart: String, thermalEnd: String) {
            self.id = id; self.run = run; self.completed = completed; self.failure = failure; self.audioSeconds = audioSeconds
            self.recordWallSeconds = recordWallSeconds; self.missingAudioEvents = missingAudioEvents
            self.stopToTranscriptSeconds = stopToTranscriptSeconds; self.stopToNotesSeconds = stopToNotesSeconds; self.stages = stages
            self.peakAppMiB = peakAppMiB; self.peakWorkerMiB = peakWorkerMiB; self.workerPIDs = workerPIDs
            self.thermalStart = thermalStart; self.thermalEnd = thermalEnd
        }
    }
}
