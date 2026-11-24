#include "amr_realtime.h"

#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct amr_ring {
    uint32_t channels;
    uint32_t capacity_frames;
    uint32_t capacity_chunks;
    uint32_t first_buffer;
    uint32_t buffer_count;

    float *samples;      // capacity_frames * channels
    amr_chunk *chunks;   // capacity_chunks

    // Monotonic counters; positions are taken modulo capacity. Producer owns *_write, consumer owns *_read.
    _Atomic uint64_t frame_write;
    _Atomic uint64_t frame_read;
    _Atomic uint64_t chunk_write;
    _Atomic uint64_t chunk_read;

    // Producer-local: frames dropped since the last successfully pushed chunk.
    uint64_t pending_dropped;

    _Atomic uint64_t callbacks;
    _Atomic uint64_t frames_pushed;
    _Atomic uint64_t overrun_frames;
    _Atomic uint64_t overrun_events;
    _Atomic uint64_t format_mismatch_callbacks;
    _Atomic uint64_t last_callback_host_time;
    _Atomic uint64_t max_callback_ns;
    _Atomic uint64_t histogram[AMR_HIST_BUCKETS];
};

static mach_timebase_info_data_t amr_timebase(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return tb;
}

uint64_t amr_host_ticks_to_ns(uint64_t ticks) {
    mach_timebase_info_data_t tb = amr_timebase();
    return (uint64_t)((__uint128_t)ticks * tb.numer / tb.denom);
}

uint64_t amr_host_now_ns(void) { return amr_host_ticks_to_ns(mach_absolute_time()); }

amr_ring *amr_ring_create(uint32_t channels, uint32_t capacity_frames, uint32_t capacity_chunks) {
    if (channels == 0 || capacity_frames < AMR_MAX_CHUNK_FRAMES || capacity_chunks == 0) return NULL;
    (void)amr_timebase(); // initialize outside the realtime thread
    amr_ring *r = calloc(1, sizeof(amr_ring));
    if (!r) return NULL;
    r->channels = channels;
    r->capacity_frames = capacity_frames;
    r->capacity_chunks = capacity_chunks;
    r->first_buffer = 0;
    r->buffer_count = UINT32_MAX;
    r->samples = calloc((size_t)capacity_frames * channels, sizeof(float));
    r->chunks = calloc(capacity_chunks, sizeof(amr_chunk));
    if (!r->samples || !r->chunks) {
        amr_ring_destroy(r);
        return NULL;
    }
    // Touch pages now so the realtime thread never page-faults on first write.
    memset(r->samples, 0, (size_t)capacity_frames * channels * sizeof(float));
    memset(r->chunks, 0, capacity_chunks * sizeof(amr_chunk));
    return r;
}

void amr_ring_destroy(amr_ring *r) {
    if (!r) return;
    free(r->samples);
    free(r->chunks);
    free(r);
}

uint32_t amr_ring_channels(const amr_ring *r) { return r->channels; }
uint32_t amr_ring_capacity_frames(const amr_ring *r) { return r->capacity_frames; }

void amr_ring_set_buffer_selection(amr_ring *r, uint32_t first_buffer, uint32_t buffer_count) {
    r->first_buffer = first_buffer;
    r->buffer_count = buffer_count;
}

static void record_drop(amr_ring *r, uint32_t frames) {
    r->pending_dropped += frames;
    atomic_fetch_add_explicit(&r->overrun_frames, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->overrun_events, 1, memory_order_relaxed);
}

/// Reserves space for `frames`; returns false (and records the drop) when the ring is full.
static bool reserve(amr_ring *r, uint32_t frames, uint64_t *out_fw, uint64_t *out_cw) {
    uint64_t fw = atomic_load_explicit(&r->frame_write, memory_order_relaxed);
    uint64_t fr = atomic_load_explicit(&r->frame_read, memory_order_acquire);
    uint64_t cw = atomic_load_explicit(&r->chunk_write, memory_order_relaxed);
    uint64_t cr = atomic_load_explicit(&r->chunk_read, memory_order_acquire);
    if (fw - fr + frames > r->capacity_frames || cw - cr + 1 > r->capacity_chunks) {
        record_drop(r, frames);
        return false;
    }
    *out_fw = fw;
    *out_cw = cw;
    return true;
}

static void publish(amr_ring *r, uint64_t fw, uint64_t cw, uint32_t frames, uint64_t host_time, double sample_time,
                    uint32_t flags) {
    amr_chunk *c = &r->chunks[cw % r->capacity_chunks];
    c->host_time = host_time;
    c->sample_time = sample_time;
    c->frame_count = frames;
    c->flags = flags;
    c->dropped_frames_before = r->pending_dropped;
    r->pending_dropped = 0;
    atomic_store_explicit(&r->frame_write, fw + frames, memory_order_release);
    atomic_store_explicit(&r->chunk_write, cw + 1, memory_order_release);
    atomic_fetch_add_explicit(&r->frames_pushed, frames, memory_order_relaxed);
}

void amr_ring_push(amr_ring *r, const AudioBufferList *in, const AudioTimeStamp *t) {
    if (!in || in->mNumberBuffers == 0) return;
    uint32_t first = r->first_buffer;
    uint32_t count = r->buffer_count == UINT32_MAX ? in->mNumberBuffers - first : r->buffer_count;
    if (first + count > in->mNumberBuffers || count == 0) {
        atomic_fetch_add_explicit(&r->format_mismatch_callbacks, 1, memory_order_relaxed);
        return;
    }
    // Validate channel layout: total channels across selected buffers must equal ring channels.
    uint32_t total_ch = 0;
    for (uint32_t b = first; b < first + count; b++) total_ch += in->mBuffers[b].mNumberChannels;
    const AudioBuffer *b0 = &in->mBuffers[first];
    if (total_ch != r->channels || b0->mNumberChannels == 0) {
        atomic_fetch_add_explicit(&r->format_mismatch_callbacks, 1, memory_order_relaxed);
        return;
    }
    uint32_t frames = b0->mDataByteSize / (uint32_t)(sizeof(float) * b0->mNumberChannels);

    uint32_t flags = 0;
    uint64_t host = 0;
    double stime = 0;
    if (t && (t->mFlags & kAudioTimeStampHostTimeValid)) { flags |= AMR_CHUNK_HOST_TIME_VALID; host = t->mHostTime; }
    if (t && (t->mFlags & kAudioTimeStampSampleTimeValid)) { flags |= AMR_CHUNK_SAMPLE_TIME_VALID; stime = t->mSampleTime; }

    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done;
        if (n > AMR_MAX_CHUNK_FRAMES) n = AMR_MAX_CHUNK_FRAMES;
        uint64_t fw, cw;
        if (reserve(r, n, &fw, &cw)) {
            for (uint32_t i = 0; i < n; i++) {
                float *dst = &r->samples[((fw + i) % r->capacity_frames) * r->channels];
                uint32_t ch = 0;
                for (uint32_t b = first; b < first + count; b++) {
                    const AudioBuffer *buf = &in->mBuffers[b];
                    const float *src = (const float *)buf->mData + (size_t)(done + i) * buf->mNumberChannels;
                    for (uint32_t c = 0; c < buf->mNumberChannels; c++) dst[ch++] = src[c];
                }
            }
            // Sub-chunk host time is left as the callback's; the consumer derives exact times from sample counts.
            publish(r, fw, cw, n, host, stime + done, flags);
        }
        done += n;
    }
}

static void note_callback(amr_ring *r, uint64_t t0, uint64_t t1);

void amr_ring_push_interleaved(amr_ring *r, const float *frames, uint32_t frame_count, uint64_t host_time,
                               double sample_time) {
    uint64_t t0 = mach_absolute_time();
    uint32_t done = 0;
    while (done < frame_count) {
        uint32_t n = frame_count - done;
        if (n > AMR_MAX_CHUNK_FRAMES) n = AMR_MAX_CHUNK_FRAMES;
        uint64_t fw, cw;
        if (reserve(r, n, &fw, &cw)) {
            for (uint32_t i = 0; i < n; i++) {
                memcpy(&r->samples[((fw + i) % r->capacity_frames) * r->channels],
                       &frames[(size_t)(done + i) * r->channels], r->channels * sizeof(float));
            }
            publish(r, fw, cw, n, host_time, sample_time + done,
                    AMR_CHUNK_HOST_TIME_VALID | AMR_CHUNK_SAMPLE_TIME_VALID);
        }
        done += n;
    }
    note_callback(r, t0, mach_absolute_time());
}

bool amr_ring_pop(amr_ring *r, amr_chunk *out, float *dst) {
    uint64_t cr = atomic_load_explicit(&r->chunk_read, memory_order_relaxed);
    uint64_t cw = atomic_load_explicit(&r->chunk_write, memory_order_acquire);
    if (cr == cw) return false;
    *out = r->chunks[cr % r->capacity_chunks];
    uint64_t fr = atomic_load_explicit(&r->frame_read, memory_order_relaxed);
    for (uint32_t i = 0; i < out->frame_count; i++) {
        memcpy(&dst[(size_t)i * r->channels], &r->samples[((fr + i) % r->capacity_frames) * r->channels],
               r->channels * sizeof(float));
    }
    atomic_store_explicit(&r->frame_read, fr + out->frame_count, memory_order_release);
    atomic_store_explicit(&r->chunk_read, cr + 1, memory_order_release);
    return true;
}

uint32_t amr_ring_buffered_frames(const amr_ring *r) {
    uint64_t fw = atomic_load_explicit(&((amr_ring *)r)->frame_write, memory_order_acquire);
    uint64_t fr = atomic_load_explicit(&((amr_ring *)r)->frame_read, memory_order_acquire);
    return (uint32_t)(fw - fr);
}

void amr_ring_stats(const amr_ring *cr, amr_stats *out) {
    amr_ring *r = (amr_ring *)cr;
    out->callbacks = atomic_load_explicit(&r->callbacks, memory_order_relaxed);
    out->frames_pushed = atomic_load_explicit(&r->frames_pushed, memory_order_relaxed);
    out->overrun_frames = atomic_load_explicit(&r->overrun_frames, memory_order_relaxed);
    out->overrun_events = atomic_load_explicit(&r->overrun_events, memory_order_relaxed);
    out->format_mismatch_callbacks = atomic_load_explicit(&r->format_mismatch_callbacks, memory_order_relaxed);
    out->last_callback_host_time = atomic_load_explicit(&r->last_callback_host_time, memory_order_relaxed);
    out->max_callback_ns = atomic_load_explicit(&r->max_callback_ns, memory_order_relaxed);
    for (uint32_t i = 0; i < AMR_HIST_BUCKETS; i++)
        out->histogram[i] = atomic_load_explicit(&r->histogram[i], memory_order_relaxed);
}

static void note_callback(amr_ring *r, uint64_t t0, uint64_t t1) {
    atomic_fetch_add_explicit(&r->callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&r->last_callback_host_time, t1, memory_order_relaxed);
    uint64_t ns = amr_host_ticks_to_ns(t1 - t0);
    uint64_t bucket = ns / AMR_HIST_BUCKET_NS;
    if (bucket >= AMR_HIST_BUCKETS) bucket = AMR_HIST_BUCKETS - 1;
    atomic_fetch_add_explicit(&r->histogram[bucket], 1, memory_order_relaxed);
    uint64_t prev = atomic_load_explicit(&r->max_callback_ns, memory_order_relaxed);
    while (ns > prev && !atomic_compare_exchange_weak_explicit(&r->max_callback_ns, &prev, ns, memory_order_relaxed,
                                                               memory_order_relaxed)) {
    }
}

OSStatus amr_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *inInputData,
                    const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData,
                    const AudioTimeStamp *inOutputTime, void *client_data) {
    (void)device; (void)now; (void)outOutputData; (void)inOutputTime;
    uint64_t t0 = mach_absolute_time();
    amr_ring *r = (amr_ring *)client_data;
    amr_ring_push(r, inInputData, inInputTime);
    note_callback(r, t0, mach_absolute_time());
    return noErr;
}

OSStatus amr_create_ioproc(AudioObjectID device, amr_ring *ring, AudioDeviceIOProcID *out_proc_id) {
    return AudioDeviceCreateIOProcID(device, amr_ioproc, ring, out_proc_id);
}
