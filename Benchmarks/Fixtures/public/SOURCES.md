# Public test audio: sources, licenses, hashes

Fetched 2026-10-16 for T02 smoke tests (ASR and diarization). The total is about 180 MB.
These are public read-speech and scenario-meeting recordings. Per the development plan §10 they may **supplement, not replace**, consented captured calls.
`SHA256SUMS` in this directory lists all 104 files. Check them with `shasum -a 256 -c SHA256SUMS`.

## AMI Meeting Corpus: ES2004a, IS1009a, EN2002a

- License: **CC BY 4.0** for both the corpus and its annotations (see `ami/annotations-1.6.2/LICENCE.txt`). Attribution: "AMI Meeting Corpus, University of Edinburgh / AMI Consortium".
- Audio is 16 kHz, mono, Int16 WAV, downloaded from `https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/<meeting>/audio/<file>`.
- All three meetings are in the standard AMI "Full-corpus-ASR" **test** split, so they are suitable as held-out data.

| File | Duration | Speakers | sha256 |
|---|---|---|---|
| `ami/ES2004a/ES2004a.Mix-Headset.wav` | 1049.35 s | 4 | `3e2560b19bee6952c7c7ce041b0f1ea8a7ea9468044c4eea79d2a2c67e24ab0f` |
| `ami/ES2004a/ES2004a.Array1-01.wav` (single far-field array mic, i.e. room/speakerphone-like) | 1049.35 s | 4 | `6936edac5d0904fc5c4ab175546c5cc5366601fdc1b1e5183a6ea2c10f05d150` |
| `ami/IS1009a/IS1009a.Mix-Headset.wav` | 838.83 s | 4 | `6eb5a0ede0d9e72794f976ce7bea5b78133eae969f99b4c5418b43c2468d25b1` |
| `ami/EN2002a/EN2002a.Mix-Headset.wav` (spontaneous, non-scenario meeting) | 2142.71 s | 4 | `a15017d0d3c871866971ee178052a0ce3a7e44d6fbf89fc23dcab326511b65f5` |

Diarization references (RTTM and UEM):
- Source: BUTSpeechFIT/AMI-diarization-setup at commit `2509d8933721023fab4def2618aabd5c28eb82e9`, from `https://raw.githubusercontent.com/BUTSpeechFIT/AMI-diarization-setup/2509d8933721023fab4def2618aabd5c28eb82e9/{only_words,word_and_vocalsounds}/rttms/test/<m>.rttm` and `…/uems/test/<m>.uem`.
- The repo license is Apache-2.0 (`ami/AMI-diarization-setup.LICENSE`). The labels are derived from the CC BY 4.0 AMI manual word alignments.
- `<m>.only_words.rttm` is the usual reference for DER.
- `<m>.word_and_vocalsounds.rttm` also includes laughs and other vocal sounds.

| File | sha256 |
|---|---|
| `ami/ES2004a/ES2004a.only_words.rttm` | `9869c6146c2fd9595403edb36c2caeda65c12ffa2c0af4ce48d6814b673fd5a9` |
| `ami/ES2004a/ES2004a.word_and_vocalsounds.rttm` | `3cd0e683ebb4e6f8c4a129d5fbff9a6983f7a2c687c897603efc169f04563a1a` |
| `ami/ES2004a/ES2004a.uem` | `514373eae2841ddf15fb07938a7d74bbecc2acad8afc2a28a93e0f7b24bfb446` |
| `ami/IS1009a/IS1009a.only_words.rttm` | `ba38d35ca567f3f1e061d90fdc33579ce60d2060fc8664eaeb77d2e0fcd88b01` |
| `ami/IS1009a/IS1009a.word_and_vocalsounds.rttm` | `74646fd4187b5e4446b4ac1291a0d1bb81f0378a0e38f94603af3b29c8af99ac` |
| `ami/IS1009a/IS1009a.uem` | `afdc9548c0178876108b7ac88b0464ace094fab910c5e8661c135837b81514c6` |
| `ami/EN2002a/EN2002a.only_words.rttm` | `a93919ae5f18e476614b7e5a2713c4dc6bba23e95149fba18dbe68602b13ee40` |
| `ami/EN2002a/EN2002a.word_and_vocalsounds.rttm` | `7ca6c37a334290205cb3297154eb7dfe22bca5b9a249bf04ea8c5d0e64e52069` |
| `ami/EN2002a/EN2002a.uem` | `3126782a9c64efc2ed2919b8c9e1666a6254b1abedf6279de9512829472244d1` |

Reference transcripts and summaries:
- Source: AMI manual annotations v1.6.2, `https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip` (zip sha256 `b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d`, 22,887,865 bytes). License CC BY 4.0. Only a subset was extracted.
- `ami/<m>/words/<m>.<A-D>.words.xml`: word-level transcripts with start and end times, one file per speaker channel. Use these for WER and word-timestamp checks.
- `ami/<m>/segments/<m>.<A-D>.segments.xml`: speaker segments.
- `ami/<m>/summaries/<m>.abssumm.xml` and `<m>.extsumm.xml`: abstractive and extractive summaries. Useful as a rough reference for meeting notes. No decision annotations exist for these three meetings.
- `ami/annotations-1.6.2/`: `LICENCE.txt`, `00README_MANUAL.txt`, `MANIFEST_MANUAL.txt`, and `meetings.xml`/`participants.xml`, which map channels A-D to speaker IDs.

## LibriSpeech test-clean: two chapters

- License: **CC BY 4.0** (`librispeech-test-clean/LICENSE.TXT`). Panayotov et al., 2015.
- Source: `https://www.openslr.org/resources/12/test-clean.tar.gz` (sha256 `39fde525e59672dc6d1551919b1478f724438a95aa55f874b576be21967e6c23`, 346,663,984 bytes). Only two chapters were extracted.
- `librispeech-test-clean/1089/134686/`: speaker 1089 (M), 38 utterances, FLAC 16 kHz. Transcript `1089-134686.trans.txt`, sha256 `acc2353d5507053a02adc1ecb8d497bf3453a60d32fe7da97577d1c212c9b075`.
- `librispeech-test-clean/121/121726/`: speaker 121 (F), 15 utterances. Transcript `121-121726.trans.txt`, sha256 `aef21ad2ec551651cada3748a10e592091a61e4c89effe68aca96674a1bb7f43`.
- Transcripts are upper-case and unpunctuated. Normalize both sides before scoring WER.

## Not included

- VoxConverse: the dev audio zip is larger than this budget allowed.
- Silence and music controls: still needed, see plan §10.
- Short trimmed excerpts: none were made. The harness should cut segments from the AMI files at run time and record the offsets, rather than storing derived audio.
