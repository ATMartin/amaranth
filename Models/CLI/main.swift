import Foundation
import Domain
import Models

// amaranth-models — build, install and verify model packs (T04).
//
//   amaranth-models build-pack <ModelStore> <out.json> --pack <id> --version <v> --models dirA,dirB[...]
//                              [--profile standard16GB|experimental8GB] [--exclude substr,…]
//   amaranth-models install <pack.json> (--from-dir <dir> | --from-network) [--store <root>]
//   amaranth-models verify [--store <root>] [--full]
//   amaranth-models status [--store <root>]

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let store = ModelPackStore(root: value("--store").map { URL(filePath: $0) } ?? ModelPackStore.defaultRoot())

/// Per-directory metadata for the known pinned models (provenance and licensing notes from candidates.md).
struct Known { let role: ModelRole; let family: String; let provenance: String; let license: String; let attribution: String
               let tokenizer: String?; let template: String? }
let known: [String: Known] = [
    "parakeet-tdt-0.6b-v2-coreml": Known(role: .asr, family: "parakeet-tdt-0.6b-v2",
        provenance: "FluidInference Core ML conversion of nvidia/parakeet-tdt-0.6b-v2 (coremltools 9.0b1, torch 2.7.0, 2025-09-25); exact NVIDIA revision not recorded upstream",
        license: "CC-BY-4.0", attribution: "NVIDIA Parakeet TDT 0.6B v2 (CC-BY-4.0); Core ML conversion by Fluid Inference", tokenizer: "parakeet_vocab.json", template: nil),
    "parakeet-tdt-0.6b-v3-coreml": Known(role: .asr, family: "parakeet-tdt-0.6b-v3",
        provenance: "FluidInference/mobius Core ML conversion of nvidia/parakeet-tdt-0.6b-v3",
        license: "CC-BY-4.0", attribution: "NVIDIA Parakeet TDT 0.6B v3, governed by CC-BY-4.0 (NVIDIA model card, included); Core ML conversion by Fluid Inference. The converter README's \"Apache 2.0\" statement does not override NVIDIA's governing license.", tokenizer: "parakeet_vocab.json", template: nil),
    "speaker-diarization-coreml": Known(role: .diarizationSegmentation, family: "pyannote-community-1+wespeaker+vbx",
        provenance: "Fluid Inference Core ML export of pyannote/speaker-diarization-community-1@3533c8cf; PROVENANCE.md: historically reconstructed, not build-attested",
        license: "CC-BY-4.0", attribution: "pyannote speaker-diarization-community-1 (CC-BY-4.0), WeSpeaker, BUT Speech@FIT VBx/PLDA, Fluid Inference conversion", tokenizer: nil, template: nil),
    "silero-vad-coreml": Known(role: .vad, family: "silero-vad-6.2.1", provenance: "Fluid Inference Core ML conversion via onnx-community/silero-vad",
        license: "MIT", attribution: "Silero VAD (MIT)", tokenizer: nil, template: nil),
    "openai_whisper-large-v3-v20240930": Known(role: .asr, family: "whisper-large-v3-turbo", provenance: "argmaxinc/whisperkit-coreml conversion",
        license: "MIT", attribution: "OpenAI Whisper large-v3-turbo (MIT); WhisperKit Core ML conversion by Argmax", tokenizer: "openai-whisper-large-v3-tokenizer", template: nil),
    "openai_whisper-large-v3-v20240930_626MB": Known(role: .asr, family: "whisper-large-v3-turbo-626MB", provenance: "argmaxinc/whisperkit-coreml mixed-bit palettized conversion",
        license: "MIT", attribution: "OpenAI Whisper large-v3-turbo (MIT); WhisperKit Core ML conversion by Argmax", tokenizer: "openai-whisper-large-v3-tokenizer", template: nil),
    "openai-whisper-large-v3-tokenizer": Known(role: .asr, family: "whisper-tokenizer", provenance: "openai/whisper-large-v3 tokenizer files",
        license: "Apache-2.0", attribution: "OpenAI Whisper tokenizer", tokenizer: nil, template: nil),
    "qwen3-4b-instruct-2507-q4_k_m": Known(role: .summary, family: "qwen3-4b-instruct-2507", provenance: "bartowski GGUF Q4_K_M (llama.cpp b6096, imatrix) of Qwen/Qwen3-4B-Instruct-2507",
        license: "Apache-2.0", attribution: "Qwen3-4B-Instruct-2507 (Apache-2.0), Alibaba Qwen team; GGUF by bartowski", tokenizer: "embedded GGUF tokenizer", template: "chatml-manual-v1"),
    "qwen3-1.7b-q4_k_m": Known(role: .summary, family: "qwen3-1.7b", provenance: "bartowski GGUF Q4_K_M (llama.cpp b5200, imatrix) of Qwen/Qwen3-1.7B; non-thinking mode",
        license: "Apache-2.0", attribution: "Qwen3-1.7B (Apache-2.0), Alibaba Qwen team; GGUF by bartowski", tokenizer: "embedded GGUF tokenizer", template: "chatml-manual-v1+empty-think"),
]

struct DirManifest: Decodable {
    struct F: Decodable { let path: String; let sha256: String; let byteSize: Int64; let sourceURL: String; let repo: String; let revision: String }
    let files: [F]
}

func buildPack() throws {
    guard args.count >= 4, let id = value("--pack"), let version = value("--version"), let models = value("--models") else {
        throw ModelInstallError.invalidManifest("usage: build-pack <ModelStore> <out.json> --pack id --version v --models a,b")
    }
    let src = URL(filePath: args[2])
    let excludes = value("--exclude")?.split(separator: ",").map(String.init) ?? []
    let profile = HardwareProfile(rawValue: value("--profile") ?? "standard16GB") ?? .standard16GB
    var manifests: [ModelManifest] = []
    for dir in models.split(separator: ",").map(String.init) {
        guard let k = known[dir] else { throw ModelInstallError.invalidManifest("unknown model directory \(dir)") }
        let m = try JSONDecoder().decode(DirManifest.self, from: Data(contentsOf: src.appending(path: dir).appending(path: "manifest.json")))
        let files = m.files.filter { f in !excludes.contains { f.path.contains($0) } }
        // Primary provenance = the repo of the weights (largest file), not e.g. an upstream LICENSE copied alongside.
        guard let first = files.max(by: { $0.byteSize < $1.byteSize }) else { throw ModelInstallError.invalidManifest("\(dir): no files") }
        // License/notice texts may come from upstream license sources; every other file must share one revision.
        func isNotice(_ p: String) -> Bool { p.hasPrefix("LICENSE") || p.hasPrefix("NOTICE") || p.hasPrefix("NVIDIA-MODEL-CARD") }
        let revisions = Set(files.filter { !isNotice($0.path) && $0.path != "tokenizer_config.json" }.map(\.revision))
        guard revisions.count == 1 else { throw ModelInstallError.invalidManifest("\(dir): mixed revisions \(revisions)") }
        let noticePath = files.first { $0.path.hasPrefix("LICENSE") }?.path ?? files.first { $0.path.hasPrefix("NOTICE") }?.path
        manifests.append(ModelManifest(
            id: ModelManifestID(dir), version: String(first.revision.prefix(12)), role: k.role, family: k.family,
            sourceRepository: first.repo, sourceRevision: first.revision, conversionProvenance: k.provenance,
            tokenizerIdentity: k.tokenizer, promptTemplateIdentity: k.template,
            files: files.map { ModelFile(path: $0.path, sha256: $0.sha256, byteSize: $0.byteSize, sourceURL: URL(string: $0.sourceURL)) },
            license: ModelLicense(identifier: k.license, noticePath: noticePath, attribution: k.attribution),
            minimumOS: "26.5.2"))
    }
    let pack = ModelPack(id: id, version: version, profile: profile, manifests: manifests)
    for m in manifests { try m.validatePinning() }
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try e.encode(Versioned(pack)).write(to: URL(filePath: args[3]))
    let total = manifests.reduce(0) { $0 + $1.totalBytes }
    print("pack \(id) \(version): \(manifests.count) models, \(manifests.map(\.files.count).reduce(0, +)) files, \(String(format: "%.2f", Double(total) / 1e9)) GB")
    for m in manifests { print("  \(m.id)  \(m.family)  \(m.sourceRepository)@\(m.sourceRevision.prefix(12))  \(m.files.count) files  \(String(format: "%.1f", Double(m.totalBytes) / 1e6)) MB  \(m.license.identifier)") }
}

func install() async throws {
    guard args.count >= 3 else { throw ModelInstallError.invalidManifest("usage: install <pack.json> --from-dir <dir> | --from-network") }
    let pack = try ContractCoding.decode(ModelPack.self, from: Data(contentsOf: URL(filePath: args[2])))
    let source: any ModelSource = if let dir = value("--from-dir") { DirectoryModelSource(root: URL(filePath: dir)) }
        else if args.contains("--from-network") { HTTPModelSource() }
        else { throw ModelInstallError.invalidManifest("choose --from-dir or --from-network") }
    let installer = ModelInstaller(store: store)
    print("installing \(pack.id) \(pack.version) into \(store.root.path); requires \(String(format: "%.2f", Double(installer.requiredBytes(for: pack)) / 1e9)) GB free")
    let last = LastPrint()
    try await installer.install(pack, from: source) { p in
        if last.shouldPrint(p) {
            print(String(format: "  %@ %.1f%% %@", p.phase.rawValue, p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) * 100 : 0, p.currentFile ?? ""))
        }
    }
    print("active: \(store.activePack().map { "\($0.packID) \($0.version)" } ?? "none")")
}

final class LastPrint: @unchecked Sendable {
    private let lock = NSLock(); private var phase: InstallProgress.Phase?; private var pct = -1
    func shouldPrint(_ p: InstallProgress) -> Bool {
        lock.withLock {
            let pc = p.bytesTotal > 0 ? Int(Double(p.bytesDone) / Double(p.bytesTotal) * 20) : 0
            defer { phase = p.phase; pct = pc }
            return p.phase != phase || pc != pct
        }
    }
}

func verify() {
    let reg = LocalModelRegistry(store: store, verification: args.contains("--full") ? .fullHash : .sizes)
    print("\(reg.state())")
}

do {
    switch args.dropFirst().first {
    case "build-pack": try buildPack()
    case "install": try await install()
    case "verify", "status": verify()
    default: print("usage: amaranth-models build-pack|install|verify|status …"); exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
