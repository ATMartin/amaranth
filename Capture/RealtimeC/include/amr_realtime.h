// Realtime capture primitives for Amaranth.
//
// Everything reachable from amr_ioproc() is lock-free, allocation-free and free of Swift runtime calls:
// it copies frames into a preallocated single-producer/single-consumer ring and updates atomic counters.
// The consumer (segment writer) runs on its own thread. See docs/development-plan.txt §6 "Realtime callback".
#ifndef AMR_REALTIME_H
#define AMR_REALTIME_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Largest frame count stored in a single chunk. Larger IO buffers are split.
#define AMR_MAX_CHUNK_FRAMES 4096u
/// Callback-duration histogram: AMR_HIST_BUCKETS buckets of AMR_HIST_BUCKET_NS each, last bucket = overflow.
#define AMR_HIST_BUCKETS 400u
#define AMR_HIST_BUCKET_NS 25000ull

enum {
    AMR_CHUNK_HOST_TIME_VALID = 1u << 0,
    AMR_CHUNK_SAMPLE_TIME_VALID = 1u << 1,
};

typedef struct amr_chunk {
    /// Host time (mach absolute ticks) of the first frame, from the IOProc input timestamp.
    uint64_t host_time;
    /// Device sample time of the first frame.
    double sample_time;
    uint32_t frame_count;
    uint32_t flags;
    /// Frames dropped because the ring was full, immediately before this chunk.
    uint64_t dropped_frames_before;
} amr_chunk;

typedef struct amr_stats {
    uint64_t callbacks;
    uint64_t frames_pushed;
    uint64_t overrun_frames;
    uint64_t overrun_events;
    uint64_t format_mismatch_callbacks;
    uint64_t last_callback_host_time;
    uint64_t max_callback_ns;
    uint64_t histogram[AMR_HIST_BUCKETS];
} amr_stats;

typedef struct amr_ring amr_ring;

/// Allocates a ring for `channels` interleaved float32 channels. Call off the realtime thread.
/// `capacity_frames` should cover two seconds of the source's maximum supported format.
amr_ring *amr_ring_create(uint32_t channels, uint32_t capacity_frames, uint32_t capacity_chunks);
void amr_ring_destroy(amr_ring *ring);

uint32_t amr_ring_channels(const amr_ring *ring);
uint32_t amr_ring_capacity_frames(const amr_ring *ring);

/// Selects which AudioBuffers of the IOProc input list belong to this source (e.g. the tap stream inside an
/// aggregate device). Must be set before the IOProc starts.
void amr_ring_set_buffer_selection(amr_ring *ring, uint32_t first_buffer, uint32_t buffer_count);

/// Producer: copies `inData` (interleaved or non-interleaved float32) into the ring. Realtime-safe.
void amr_ring_push(amr_ring *ring, const AudioBufferList *inData, const AudioTimeStamp *inTime);

/// Producer for tests/synthetic sources: pushes interleaved frames. Realtime-safe.
void amr_ring_push_interleaved(amr_ring *ring, const float *frames, uint32_t frame_count, uint64_t host_time,
                               double sample_time);

/// Consumer: pops one chunk into `dst` (capacity >= AMR_MAX_CHUNK_FRAMES * channels floats).
/// Returns false if the ring is empty.
bool amr_ring_pop(amr_ring *ring, amr_chunk *out_chunk, float *dst);

/// Number of frames currently buffered (approximate; for health/diagnostics).
uint32_t amr_ring_buffered_frames(const amr_ring *ring);

/// Snapshot of counters (any thread).
void amr_ring_stats(const amr_ring *ring, amr_stats *out);

/// Core Audio IOProc. `client_data` must be an amr_ring*. Records its own execution time in the histogram.
OSStatus amr_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *inInputData,
                    const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData,
                    const AudioTimeStamp *inOutputTime, void *client_data);

/// Registers amr_ioproc on `device` with `ring` as client data (keeps function-pointer handling in C).
OSStatus amr_create_ioproc(AudioObjectID device, amr_ring *ring, AudioDeviceIOProcID *out_proc_id);

/// mach ticks → nanoseconds.
uint64_t amr_host_ticks_to_ns(uint64_t ticks);
uint64_t amr_host_now_ns(void);

#ifdef __cplusplus
}
#endif

#endif
