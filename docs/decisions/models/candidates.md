# T02 model and runtime candidates: pins

Status: research and pinning only. Nothing here is a benchmark result or a final selection.
Checked on 2026-10-15/16 on the M2 Max, macOS 26.5.2, Xcode 26.6 (17F113), Swift 6.3.3.
Claims marked **(unverified)** were not checked against source or by running code.

## 1. Swift packages and binaries

| Package | Pin (tag → commit) | Released | tools-version / min OS | Builds on macOS 26.5 + Xcode 26.6? | Code license |
|---|---|---|---|---|---|
| FluidAudio `github.com/FluidInference/FluidAudio` | `v0.17.7` (annotated tag object `2437bf2a65dc070eabf24e339f9d5a9723a5a8bf`) → commit `503b4bd1bbf7220882de39fe8ae6716aae4132da` | 2026-10-08 | `Package.swift` 6.0; `Package@swift-6.2.swift` 6.2 (Swift 6.3.3 uses this one). macOS 14 / iOS 17 | **Yes.** A throwaway consumer package (platform macOS 26, `exact: "0.17.7"`, `traits: []`) built in release mode with no errors | Apache-2.0 |
| Argmax OSS Swift (WhisperKit, SpeakerKit, TTSKit) `github.com/argmaxinc/argmax-oss-swift` | `v1.1.1` (lightweight tag) → commit `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4` | 2026-10-08 | 5.10 / 6.2 manifests. macOS 13 / iOS 16 | **Yes.** It was in the same consumer build (`WhisperKit` + `SpeakerKit` products) | MIT |
| llama.cpp `github.com/ggml-org/llama.cpp` | `b11669`, commit `620d2225cc436ab0b001e3200e590e3b286ef9ab`. This is the commit of stable release `v0.7.0` (annotated tag `757cad02…`). The `v0.7.0` release has no binaries, but its `nightly-tag.txt` names `b11669` | 2026-10-15 | xcframework slices: `macos-arm64_x86_64` (LC_BUILD_VERSION minos 13.3, sdk 26.4) and `ios-arm64` | **Yes.** It worked as a SwiftPM `binaryTarget` (macOS 26 platform). `llama_backend_init()` ran, Metal initialised, and `EMBED_LIBRARY = 1` | MIT |

Other dependencies these pins pull in:
- FluidAudio has a binary target `NemoTextProcessing.xcframework` (FluidInference/text-processing-rs v0.3.1, checksum `5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa`). With tools 6.2 or later you can stop it being linked: `.package(url: …FluidAudio.git, exact: "0.17.7", traits: [])`. SwiftPM still downloads the zip during resolution. It is only needed for TTS and ITN.
- argmax-oss-swift depends on `swift-argument-parser` (`from: 1.7.0`; resolved 1.8.2 at `6a52f3251125d74daf04fcbd5e6f08a75d074382`), which only the CLI uses. Its 6.2 manifest puts `unsafeFlags(["-enable-library-evolution", …])` on the library targets. SwiftPM 6.3.3 accepted this for a dependency pinned by version.
- WhisperKit no longer has its own repo. `api.github.com/repos/argmaxinc/WhisperKit` redirects to `argmaxinc/argmax-oss-swift`.

llama.cpp binaryTarget:

```swift
.binaryTarget(
    name: "llama",
    url: "https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-xcframework.zip",
    checksum: "937891f26734c29c80817cdf8bf59b139c84a9c6fb36a4ad6ce31cceea608e7c"
)
```

- Zip size: 65,914,922 bytes. `swift package compute-checksum` gives the same value as `shasum -a 256`, and it matches the digest GitHub reports for the asset. The framework sits at `build-apple/llama.xcframework` inside the zip, and SwiftPM accepts that layout.
- Newest nightly at the time of checking: `b11675` (commit `2851b3bc…`, 2026-10-16). GitHub now marks every `bNNNN` build as a *prerelease*. Only `v0.7.0` is a full release, which is why we pin the build that matches it.
- There is no usable SwiftPM package in the repo. `Package.swift` does not exist at `b11669` (GitHub contents API returns 404). Use the binaryTarget above. Alternatively, build `build-xcframework.sh` from the tag ourselves.
- API drift to know about: `llama_model_params.use_mmap` has been removed. It is replaced by `enum llama_load_mode load_mode` (`LLAMA_LOAD_MODE_MMAP`, …). These are still present: `llama_model_load_from_file`, `llama_model_chat_template`, `llama_chat_apply_template`, `llama_sampler_init_grammar` (constrained generation).

## 2. Model pins (Hugging Face)

All files were downloaded from `https://huggingface.co/<repo>/resolve/<sha>/<path>`. Every file was checked as follows: LFS files against the HF LFS sha256, other files against the git blob sha1, and all files against byte size. Each directory's `manifest.json` lists `path, sha256, byteSize, sourceURL, repo, revision, license`.

| Local dir (`ModelStore/…`) | HF repo @ revision | Files / bytes | License | Upstream / provenance |
|---|---|---|---|---|
| `parakeet-tdt-0.6b-v2-coreml` | `FluidInference/parakeet-tdt-0.6b-v2-coreml` @ `ee09c569f73759e6d44c9bd16766f477b2b36d39` | 23 / 464,414,915 | CC-BY-4.0 | `nvidia/parakeet-tdt-0.6b-v2` (CC-BY-4.0; current main `ae9ad070…`). Core ML conversion by FluidInference with coremltools 9.0b1, torch 2.7.0, 2025-09-25 (from `metadata.json`). The exact NVIDIA revision used is not recorded **(gap)** |
| `parakeet-tdt-0.6b-v3-coreml` | `FluidInference/parakeet-tdt-0.6b-v3-coreml` @ `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe` | 33 / 1,377,266,703 | CC-BY-4.0 in card metadata. The README body says "Apache 2.0", which contradicts it. Treat as CC-BY-4.0, which is NVIDIA's license | `nvidia/parakeet-tdt-0.6b-v3` (CC-BY-4.0; main `541d1f99…`). Converted with FluidInference/mobius `models/stt/parakeet-tdt-v3-0.6b/coreml` (main, not pinned). Includes all three encoders: `Encoder` (6-bit LUT, despite the "int8" label), `Encoder_v2` (int8 per-channel, fixes FluidAudio#760), `EncoderInt4` (needs macOS 15+) |
| `speaker-diarization-coreml` | `FluidInference/speaker-diarization-coreml` @ `df2625ac79a7ac6b65ad868fee6d80f320da4232`. This is the revision FluidAudio 0.17.7 hard-codes in `Repo.diarizer.revision`. Main is `7eab74f3…`, which changes documentation only | 27 / 21,639,364 | CC-BY-4.0 for the Community-1 artifact set (NOTICE.md). The legacy `pyannote_segmentation`/`wespeaker*` artifacts are excluded and were not downloaded | `pyannote/speaker-diarization-community-1@3533c8cf…` (CC-BY-4.0, gated upstream) plus BUT Speech@FIT PLDA (CC-BY-4.0). All 21 downloaded model files match the sha256 values in the repo's `provenance.json`. PROVENANCE.md says the segmentation and embedding exports are "historically reconstructed, not build-attested" |
| `silero-vad-coreml` | `FluidInference/silero-vad-coreml` @ `b419383c55c110e2c9271fa6ee0ea83d03c70d96` | 7 / 1,065,899 | MIT | silero-vad v6.2.1 via `onnx-community/silero-vad`. Only `silero-vad-unified-256ms-v6.2.1.mlmodelc` was downloaded, because that is what `ModelNames.VAD` loads |
| `openai_whisper-large-v3-v20240930` | `argmaxinc/whisperkit-coreml` @ `0f63a7800b00dd0226abd051b906c246e1907482`, folder `openai_whisper-large-v3-v20240930` | 20 / 1,619,531,263 | MIT | This is **whisper-large-v3-turbo** (4 decoder layers, vocab 51866; OpenAI released turbo on 2024-09-30). It is the repo `config.json` default for M2/M3/M4. Upstream `openai/whisper-large-v3-turbo` (MIT) |
| `openai_whisper-large-v3-v20240930_626MB` | same repo and revision, folder `openai_whisper-large-v3-v20240930_626MB` | 17 / 626,718,238 | MIT | Compressed (mixed-bit palettized) turbo, listed as supported on M2. `_547MB` exists but is not listed for M2. WhisperKit's own `_turbo` suffix folders, such as `openai_whisper-large-v3-v20240930_turbo`, are a different thing: an extra `TextDecoderContextPrefill` model. They are not "large-v3-turbo" and were not downloaded |
| `openai-whisper-large-v3-tokenizer` | `openai/whisper-large-v3` @ `06f233fe06e710322aca913c1bc4249a0d71fce1` | 7 / 4,383,273 | Apache-2.0 | WhisperKit model folders contain no tokenizer. Without one, WhisperKit downloads `openai/whisper-large-v3` at runtime (see §3.2) |
| `qwen3-4b-instruct-2507-q4_k_m` | `bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF` @ `ae44f08e1392f39c0e474af10c3ff8355c8b6688`, plus `LICENSE` and `tokenizer_config.json` from `Qwen/Qwen3-4B-Instruct-2507` @ `cdbee75f17c01a7cc42f958dc650907174af0554` | 4 / 2,497,315,402 (GGUF 2,497,280,736, sha256 `2fde00ce69dd4899c70d020845e2638353015bba0fdf161b3eb965f2bca4464e`) | Apache-2.0 | No official Qwen GGUF exists for 2507-4B; `ggml-org` only has Q8_0. We chose bartowski because the card documents the llama.cpp build (`b6096`) and the imatrix calibration set, and the GGUF metadata records them. unsloth (`a06e946b…`, Q4_K_M sha256 `3605803b…`) is more downloaded but does not document how it was built |
| `qwen3-1.7b-q4_k_m` | `bartowski/Qwen_Qwen3-1.7B-GGUF` @ `dcb19155b962dbb6389f4691a982043a8e651022`, plus `LICENSE` and `tokenizer_config.json` from `Qwen/Qwen3-1.7B` @ `70d244cc86ccca08cf5af4e1e306ecf908b1ad5e` | 4 / 1,282,473,645 (GGUF sha256 `72c5c3cb38fa32d5256e2fe30d03e7a64c6c79e668ad84057e3bd66e250b24fb`) | Apache-2.0 | The official `Qwen/Qwen3-1.7B-GGUF` has only Q8_0 (1.83 GB). bartowski built this with llama.cpp `b5200` and imatrix. Hybrid thinking model: run it in non-thinking mode for the 8 GB profile |

`ModelStore/` is 7.4 GB in total, all gitignored.

**Chat template identity (must be pinned in the harness):**
- The template embedded in the Qwen3-4B-2507 GGUF has sha256 `40c21f34…` (4,040 chars). It is identical to upstream `tokenizer_config.json` at `eb25fbe4` (2025-08-06). Upstream changed the template at `cdbee75` (2025-09-17; sha256 `64f85b19…`, 2,630 chars), and that change removed the `<think>`/reasoning_content handling. Single-turn system+user prompts are probably unaffected **(unverified)**. Record which template is used. Preferably pass the upstream `cdbee75` template explicitly through `llama_chat_apply_template`.
- The template embedded in the Qwen3-1.7B GGUF (`5595e874…`) does not match upstream main (`a55ee1b1…`). Pin one explicitly.

## 3. Local-loading APIs with downloads disabled (quoted from source at the pinned tags)

### 3.1 FluidAudio 0.17.7

- **Global kill switch:** `ModelHub.offlineMode = true` (public static; backed by `HFClient.offlineMode`). Set it before any loader runs. With it on, `download`/`fetchFile`/`fetchWithAuth` throw `DownloadError.networkDisabled`, and `loadModels` throws `.modelMissing` instead of re-downloading.
- **Hazard 1:** with offline mode off, a failed load in `ModelHub.loadModels` calls `ModelCache.purgeCorruptedCache(at:)` and downloads again.
- **Hazard 2:** `OfflineDiarizerManager.prepareModels(directory:configuration:forceRedownload:)` calls `purgeDiarizerRepo(at:)` after a failed load. That runs `removeItem` on `<dir>/speaker-diarization-coreml` **whether or not offline mode is on**. Never call `prepareModels` on a model pack; load explicitly as shown below.
- **Directory layout** the `ModelHub`-based loaders expect: `<directory>/<Repo.folderName>/<file>`. The `ModelStore/` folder names match `Repo.folderName` (`parakeet-tdt-0.6b-v2-coreml`, `parakeet-tdt-0.6b-v3-coreml`, `speaker-diarization-coreml`, `silero-vad-coreml`), so `ModelStore/` itself can be passed as `directory`.
- **ASR (Parakeet TDT):**
  - `AsrModels.loadLocal(from: URL, version: AsrModelVersion = .v3, configuration: MLModelConfiguration? = nil, encoderPrecision: ParakeetEncoderPrecision = .int8, encoderComputeUnits: MLComputeUnits? = nil) throws -> AsrModels`. The doc comment says it loads "from this exact directory without downloading or resolving a repository".
    - Pass the repo folder itself, for example `ModelStore/parakeet-tdt-0.6b-v3-coreml`.
    - Use `version: .v2` or `.v3`.
    - `ParakeetEncoderPrecision` is `.int8` (`Encoder.mlmodelc`), `.int8V2` (`"int8-v2"`, `Encoder_v2.mlmodelc`) or `.int4` (`EncoderInt4.mlmodelc`).
    - Files used: `Preprocessor.mlmodelc` (CPU-only), the encoder, `Decoder.mlmodelc`, `JointDecision.mlmodelc` (v2) or `JointDecisionv3.mlmodelc` (v3), and `parakeet_vocab.json`.
  - Avoid `AsrModels.load(from:)`, `downloadAndLoad`, `loadFromCache` and `loadWithAutoRecovery`. All of them go through `ModelHub.loadModels`, which can download.
  - Run: `let asr = AsrManager(config: ASRConfig = .default, models: AsrModels?)` or `try await asr.loadModels(models)`. Then `var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)` and `try await asr.transcribe(url, decoderState: &st, language: Language? = nil)`.
  - Disk-backed long files: `transcribeDiskBacked(_:decoderState:language:)` (chosen automatically above `ASRConfig.streamingThreshold`).
  - **Word timestamps:** `ASRResult.tokenTimings: [TokenTiming]?` (`token, tokenId, startTime, endTime, confidence`). The free function `buildWordTimings(from:) -> [WordTiming]` (`word, startTime, endTime`) merges tokens into words.
- **VAD:** `VadManager(config: VadConfig = .default, vadModel: MLModel)` with `MLModel(contentsOf: ModelStore/silero-vad-coreml/silero-vad-unified-256ms-v6.2.1.mlmodelc)` makes no network calls. The other initialiser, `VadManager(config:modelDirectory:)`, looks in `<dir>/Models/silero-vad-coreml/` and goes through `ModelHub`. Methods: `process(_ url:)`, `process(_ samples:)`, `segmentSpeech(…)`, `makeStreamState()`/`processStreamingChunk(…)`.
- **Offline diarization (Community-1 / VBx):**
  - Load with `ModelHub.offlineMode = true` and `let models = try await OfflineDiarizerModels.load(from: ModelStore, configuration: nil)`. This reads `speaker-diarization-coreml/{Segmentation,Embedding,PldaRho,FBank}.mlmodelc` and `plda-parameters.json`, with FBank pinned to `.cpuOnly` and the rest `.all` by default.
  - Alternatively, build `OfflineDiarizerModels(segmentationModel:fbankModel:embeddingModel:pldaRhoModel:pldaPsi:compilationDuration:)` by hand. This needs your own decode of `plda-parameters.json` (`tensors.psi.data_base64`), because `loadPLDAPsi` is private.
  - Then `let d = OfflineDiarizerManager(config: OfflineDiarizerConfig = .default)`, `d.initialize(models:)`, and `try await d.process(url)`. `process(url)` memory-maps the file and streams it (full-file, so speaker IDs are meeting-wide).
  - Other entry points: `process(audio: [Float])`, `process(audioSource:audioLoadingSeconds:)`, and the split `prepare(…) -> PreparedDiarization` / `cluster(_:) -> DiarizationResult`.
  - Output: `DiarizationResult.segments: [TimedSpeakerSegment]` (`speakerId, startTimeSeconds, endTimeSeconds, qualityScore, embedding`).
  - Speaker count hints: `OfflineDiarizerConfig.withSpeakers(min:max:)` / `withSpeakers(exactly:)`.
- **Other notes:**
  - A keyword scan found no telemetry code in the FluidAudio, WhisperKit, ArgmaxCore or SpeakerKit sources (not audited).
  - The offline diarizer logs a known Apple BNNS crash on macOS 14 (FluidAudio#878). It does not apply on 26.x.

### 3.2 WhisperKit (argmax-oss-swift 1.1.1)

- **Config:** `WhisperKitConfig(model:downloadBase:modelRepo:modelToken:modelEndpoint:modelFolder:tokenizerFolder:computeOptions:audioInputConfig:…, verbose:logLevel:prewarm:load:download: Bool = true, useBackgroundDownloadSession:)`. Then `try await WhisperKit(config)`.
- **Local loading:** pass `modelFolder: "<ModelStore>/openai_whisper-large-v3-v20240930"` (or `…_626MB`), `download: false`, `load: true`. `setupModels` uses `modelFolder` directly when it is set.
- **Tokenizer gap:** `download: false` does **not** cover the tokenizer. `loadTokenizerIfNeeded()` → `ModelUtilities.loadTokenizer(for:tokenizerFolder:additionalSearchPaths:)` searches for a local `tokenizer.json` and otherwise *downloads `openai/whisper-large-v3` from the Hub*. The pinned turbo folders contain no tokenizer. Pass `tokenizerFolder: URL(fileURLWithPath: "<ModelStore>/openai-whisper-large-v3-tokenizer")` (its top level is searched), and block the network in tests to prove nothing is fetched.
- **Word timestamps:** `DecodingOptions(wordTimestamps: true, chunkingStrategy: .vad, …)`. The result is `TranscriptionResult.segments[].words: [WordTiming]?`.
- **Long files:** `transcribe(audioPath: String, audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental), decodeOptions:)`. `.incremental` is `.incremental(chunkDurationSeconds: 120, maxBufferedChunks: 2)`; the default is `.fullFile`.
- **SpeakerKit (fallback only):** `SpeakerKitConfig(download: Bool = true, …)`, with `PyannoteConfig(modelRepo: "argmaxinc/speakerkit-coreml", modelFolder: String?)`. Its models were not pinned or downloaded.

### 3.3 llama.cpp b11669

- Load with `llama_model_load_from_file(path, params)`, choosing `params.load_mode` explicitly.
- No network code runs unless you use the `common`/server download helpers, which are not part of the xcframework **(unverified)**.
- The Metal backend is embedded (`EMBED_LIBRARY = 1`).

## 4. Blockers and concerns

1. **No package needs anything newer than macOS 26.5.** FluidAudio needs 14+, Argmax 13+, and the llama xcframework is minos 13.3. Two model-specific floors: `EncoderInt4.mlmodelc` needs macOS 15+, and all other Core ML assets declare macOS 13 or 14 availability.
2. **Diarizer provenance is partial.** The Community-1 conversion is not build-attested (PROVENANCE.md). The upstream pyannote repo is gated ("auto" acceptance). FluidInference redistributes the conversion under CC-BY-4.0, and attribution must name pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference.
3. **Parakeet v3 license text conflicts.** The card metadata says cc-by-4.0 and the README body says Apache 2.0. Use NVIDIA's CC-BY-4.0 and its attribution requirements.
4. **Parakeet v3 default encoder.** `.int8`, the FluidAudio default, loads the 6-bit-LUT `Encoder.mlmodelc`, which has a known token-corruption issue (FluidAudio#760). Benchmark `.int8V2` as well.
5. **Data-deletion and network hazards to handle in T04:**
   - FluidAudio deletes and re-downloads the cache on a failed load unless offline mode is on.
   - `OfflineDiarizerManager.prepareModels` deletes the diarizer directory even in offline mode.
   - WhisperKit fetches the tokenizer even with `download: false`.
6. **GGUF chat templates drift from upstream** (see §2).
7. **llama.cpp nightly builds are now GitHub prereleases.** We pin the build that matches release `v0.7.0`. The binaries are CI artifacts and are not reproducible by us unless we rebuild from the tag.
