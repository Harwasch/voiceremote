# Remote ↔ iPhone BLE contract

```mermaid
flowchart LR
  Remote[Remote: controls + Opus] -->|Input / Audio notifications| Phone[iPhone: CaptureSource + trigger rules]
  Phone -->|Phone state writes| Screen[Remote screen]
  Phone --> STT[STT → dictation or AI policy]
  Remote -->|Offline: Opus segments| Flash[Temporary flash storage]
  Flash -->|Separate resumable sync| History[Phone: deferred STT → history]
```

**Draft v1.1 · unimplemented / unverified.** Inputs: [requirements](../requirements.md)
[REQ-4], [REQ-8], [REQ-18], [REQ-49–53], [REQ-56], [REQ-58], [REQ-62], [Q-5], [Q-6]; [design: Modes, Components](../system-design-v1.md).
Byte examples are synthetic, not board measurements. This is a proposed binary,
little-endian GATT contract, separate from the JSON [schema family](protocol.schema.json)
and [wire contract](wire-contract.md); no JSON types/codegen change. Codec generation
and interoperability tests for this contract remain TBD. It does not prove any requirement met.

## Service and common rules

UUIDs below were generated once for this contract; implementations use these exact
128-bit UUIDs through their Bluetooth APIs (not a little-endian integer reinterpretation).
All integer fields in characteristic values are unsigned, little-endian; offsets are
zero-based bytes. No implicit padding or terminators; only offline records below carry an explicit checksum. Reserved bytes/bits
are zero. Reject invalid lengths, enum values, reserved bits, UTF-8 and inconsistent
fields; never infer an action from malformed input. Bounds below are defensive draft
choices, not measured capacity. Text lengths count UTF-8 bytes; truncate at scalar
boundaries, exclude control characters, and render as plain text.

| GATT object | UUID | Properties / value |
|---|---|---|
| Service | `f934bb04-9472-4805-8ea8-11f9f5bcabbc` | Custom service, not Bluetooth LE Audio |
| Version/info | `cba8d4dd-2aea-4964-a0b7-ef58095a1171` | Read; fixed 20 bytes |
| Input | `9f0f839c-fe73-46e4-acc3-53518ed5689c` | Notify; fixed 14 bytes, including snapshots |
| Phone state | `d9306a59-9e64-48c5-8722-827a0592a412` | Write with response; application fragments |
| Audio | `6df454c4-b29c-4638-b4f5-cc43e81e2427` | Notify; 12-byte header + fragment |
| Offline control | `14af3886-4d49-4ccd-a2dc-3eea7b5b1577` | Write with response; fragmented requests |
| Offline result | `4fbc7f55-c428-466b-b308-771f7eac6c66` | Notify; fragmented replies |
| Offline progress | `32ac7675-c84c-4a2b-a276-ed45a9434426` | Notify; fragmented status snapshots |

All characteristics and notification subscriptions require an authenticated,
encrypted bonded link. Live capture requires subscriptions, compatible info, a fresh
snapshot and a complete phone-state write. The offline exception below permits local
capture without phone arming; it never permits live transmission before this handshake.
Compatibility: the same major version connects, whatever the minor version; a different
major disables capture and shows incompatibility. Features are gated by capability bits
only, so a 1.1 phone works with 1.0 firmware, where bit 7 clear means no sync. A newer minor
never changes an existing layout. Each side ignores capability and Input status bits it
doesn't know when the peer reports a higher minor, and sends them as zero itself; every other
reserved field is still rejected. Reconnect resets live fragment buffers, sequences,
segments and trigger history; never replay live input/audio. Persisted offline records
and resumable phone copies survive reconnect. Existing v1 byte offsets/lengths remain
unchanged; minor version, capability and Input status meanings are extended below.

## Version/info (read)

| Offset | Bytes | Field / encoding |
|---:|---:|---|
| 0 | 1 | Contract major = 1 |
| 1 | 1 | Contract minor = 1 |
| 2 | 2 | Board ID: 1 M5Stack StopWatch; 2 Waveshare ESP32-C6-Touch-LCD-1.69; 65535 synthetic/test; others reserved |
| 4 | 3 | Firmware version: major, minor, patch (one byte each) |
| 7 | 1 | Reserved |
| 8 | 2 | Capabilities: bit 0 Opus profile below; bit 1 screen; bit 2 PTT; bit 3 target-cycle; bit 4 capture control; bit 5 mode control; bit 6 `hw_mic_cut`; bit 7 offline recording + sync; others reserved |
| 10 | 1 | Mic count, 1–255; describes hardware inputs, transmitted audio remains mono |
| 11 | 1 | Slider kind: 0 physical, 1 virtual (capture and mode controls use the same kind in v1) |
| 12 | 2 | Screen width in pixels; 0 if no screen |
| 14 | 2 | Screen height in pixels; 0 if no screen |
| 16 | 2 | Maximum encoded Opus packet bytes, 1–4096 |
| 18 | 2 | Reserved |

Required v1 capabilities: bits 0–5. `hw_mic_cut=1` asserts an independent hardware
cut beyond firmware's reach; it is not a software mute indicator or a safety proof.
Both prototype boards report 0. Bit 7 is optional; when clear, omit offline
characteristics and retain live-only behavior. When set, implement this entire
extension. Firmware version has no text suffix in v1.

Example I: synthetic board 65535, firmware 0.1.2, all required capabilities plus offline recording,
no hardware cut, one mic, virtual controls, illustrative 240 × 280 screen,
maximum packet 512 bytes. Exactly 20 bytes (screen values are test data):

```hex
01 01 ff ff 00 01 02 00 bf 00 01 01 f0 00 18 01 00 02 00 00
```

## Input events and snapshots (notify)

Every notification is a full post-event snapshot, with an event discriminator.
The phone owns the shared trigger state machine for [REQ-8]; firmware only
samples/debounces controls, timestamps transitions and reports them. It does not
classify taps, double-taps, locks or approval. Control positions come from the
remote; effective live capture/recording state comes from the phone; offline state is local. Phone controls can
stop capture without moving the remote control; remote OFF always wins for this source.

| Offset | Bytes | Field / encoding |
|---:|---:|---|
| 0 | 4 | Input sequence, starts 0 per connection, increments for every notification modulo 2^32 |
| 4 | 4 | Remote monotonic milliseconds since boot, modulo 2^32; event sampling time, not notification arrival time |
| 8 | 1 | Event: 0 snapshot, 1 PTT down, 2 PTT up, 3 target-cycle press, 4 capture position changed, 5 mode position changed |
| 9 | 1 | Capture position: 0 OFF → `off`; 1 PTT → `hold`; 2 REC → `continuous` |
| 10 | 1 | Mode position: 0 TRANSCRIBE → `dictation`; 1 AI → `ai_control` |
| 11 | 1 | PTT level: 0 up, 1 down |
| 12 | 1 | Status: bit 0 live audio streaming; bit 1 recording offline; bit 2 storage full; bit 3 finalized recordings waiting; bit 4 syncing; others reserved |
| 13 | 1 | Reserved |

Example family E0–E5: sequence 42, tick 1000 ms, event byte varies as below;
PTT position, AI mode, audio stopped. Each row is exactly 14 bytes:

| Example | Hex value |
|---|---|
| E0 snapshot, up | `2a 00 00 00 e8 03 00 00 00 01 01 00 00 00` |
| E1 PTT down | `2a 00 00 00 e8 03 00 00 01 01 01 01 00 00` |
| E2 PTT up | `2a 00 00 00 e8 03 00 00 02 01 01 00 00 00` |
| E3 target-cycle press | `2a 00 00 00 e8 03 00 00 03 01 01 00 00 00` |
| E4 capture changed to PTT | `2a 00 00 00 e8 03 00 00 04 01 01 00 00 00` |
| E5 mode changed to AI | `2a 00 00 00 e8 03 00 00 05 01 01 00 00 00` |

Rows are independent examples, not a sequence. Down/up discriminator and PTT
level agree; snapshots carry no synthetic edge. Send a snapshot immediately on
Input subscription, on phone request, and after audio starts/stops. A bonded
reconnect restores the subscription, so that snapshot can arrive before the phone
is listening: the phone must not wait for it, and sets the snapshot-request flag in
its first state write instead (seen on the StopWatch with BlueZ, 2026-11-02). On a gap,
invalid transition or reconnect, the phone cancels the held/locked gesture,
stops this source, requests a snapshot and requires release then a fresh PTT
press (or a fresh deliberate REC selection) before live recording. Recovered snapshots
update displays but never cycle a target or start capture. Duplicate/stale events
are ignored; modulo sequence comparison accepts forward distances below 2^31.
Offline status changes also emit event-0 snapshots (read current state after reconnect).
Clock wrap uses modulo subtraction; a reboot disconnects and resets the session.

Ignore isolated taps shorter than 300 ms per [REQ-8]. Double-tap window and its
precedence over short-tap rejection remain **TBD**; both endpoints need the same
phone rule before enabling tap-lock. Use remote timestamps so BLE batching does
not change durations. Firmware may acquire/stream provisionally after PTT down
when armed; the phone buffers and discards rejected gestures, with no STT output
or execution before qualification. Buffer/first-word performance is **TBC**.
Capture-position or mode changes close the old audio segment and clear arm;
starting another segment waits for a complete phone state acknowledging the new
Input sequence. The phone pins mode and resolved target when accepting START;
late audio never gets reinterpreted under a new mode. Mode changes never change target. Target-cycle is one press, no implicit autorepeat: the phone
advances its current list, including Auto, then returns the resolved display state.

## Phone state (write with response)

The phone owns target registry, ordering, Auto resolution and effective capture,
mode, recording and error state. Display names are labels, never identities or
authority. The phone maps list indices to its own `Target`/device IDs. Remote
control positions are not writable. The chosen target is independent of mode.

A write carries a 6-byte fragment header followed by part of the logical state:

| Offset | Bytes | Fragment field |
|---:|---:|---|
| 0 | 2 | Transaction ID, increments modulo 2^16 per logical state |
| 2 | 2 | Total logical state length, 19–512 bytes |
| 4 | 2 | Fragment byte offset in logical state |
| 6 | remaining | Contiguous logical state bytes; at least one byte |

Write one fragment at a time with response. Offset 0 replaces an incomplete
transaction; subsequent fragments match ID/total and the exact next offset.
Reject overflow, gaps, overlaps and invalid complete states with an ATT error;
keep the previous display. Only the final valid fragment atomically applies the
state and updates the visible destination before its write response. That response
is the display barrier for [REQ-18]; the phone waits for it before insertion to a
changed resolved destination, otherwise holds insertion and reports unavailable.
Disconnect clears phone state and disables live audio; offline capture is the exception below; there is no cross-connection transaction.

| Logical offset | Bytes | Field / encoding |
|---:|---:|---|
| 0 | 1 | Flags: bit 0 request Input snapshot; bit 1 arm remote capture; others reserved |
| 1 | 1 | Capture state: 0 `off`, 1 `hold`, 2 `continuous` (effective phone decision) |
| 2 | 1 | Recording: 0 stopped, 1 recording, 2 paused, 3 error |
| 3 | 1 | Mode: 0 `dictation`, 1 `ai_control` |
| 4 | 1 | Target count N, 1–8 |
| 5 | 1 | Active index, 0–N−1; index 0 always Auto |
| 6 | 4 | Acknowledged Input sequence; arm=1 takes effect only when it's at or after the latest control event (PTT, target, capture or mode) and not ahead of the latest emitted Input, otherwise the state applies with arm treated as 0. Status snapshots don't need acknowledging |
| 10 | variable | N entries: one-byte name length (1–32), then UTF-8 name; entry 0 exactly ASCII `Auto` |
| after entries | variable | Resolved destination: one-byte length (1–32), then UTF-8 name, including when active index is Auto |
| next | variable | Link text: one-byte length (0–48), then UTF-8 text |
| next | variable | Error text: one-byte length (0–64), then UTF-8 text; empty clears error |

No trailing bytes. For a named active target, resolved name equals that entry;
Auto shows the actual resolved destination, including iPhone fallback, per [REQ-18].
The snapshot-request flag emits a new event-0 snapshot after state application.
A stale acknowledged sequence, one older than the latest control event, is not an error: the display still updates and the
remote stays disarmed, so the phone rearms with a new write after the newer event.
`off` requires stopped/paused/error recording and arm=0; arm=1 requires non-off
capture and recording=1. Live remote audio requires arm=1 AND its local capture
position not OFF; in `hold` a PTT level or phone-qualified lock is also needed.
The phone clears arm for pause, error, loss or stop. No state write overrides OFF.
A stale state cannot reopen capture after OFF: OFF clears local arming; only a
subsequent complete write following the OFF snapshot can rearm after leaving OFF.

Example P: transaction 7, 33-byte logical state, snapshot requested, disarmed/off,
stopped, dictation, acknowledged Input 42, targets Auto and PC, Auto resolved to
PC, link `BLE`, error `Mic off`. Split at a 20-byte characteristic-value budget
into three writes (20, 20 and 11 bytes):

```hex
07 00 21 00 00 00 01 00 00 00 02 00 2a 00 00 00 04 41 75 74
07 00 21 00 0e 00 6f 02 50 43 02 50 43 03 42 4c 45 07 4d 69
07 00 21 00 1c 00 63 20 6f 66 66
```

## Audio (notify)

| Profile | Draft decision |
|---|---|
| Codec | One raw Opus packet per frame, no Ogg/RTP wrapper; mono, 16 kHz, 20 ms = 320 PCM samples/frame; profile is a contract choice, not measured performance |
| Capture boundary | Remote Opus decoder feeds PCM into the phone's future `CaptureSource`, then the swappable `SttEngine`; source type `remote`, never a new authority source |
| Identifiers | Segment u32 starts at 1 per connection; increments without reuse, reconnect before overflow. Phone namespaces it with the connection/capture session, not a global JSON ID |
| Frame sequence | u16 starts 0 per segment; increments once per encoded packet, not per fragment. End segment before sequence wrap; no reuse within a segment |
| Packet bound | Nonempty, at most the Version/info maximum (up to 4096 bytes); defensive bound, not bitrate |
| Bitrate / throughput | Encoder bitrate, sustainable iOS throughput, latency, power and both boards' encode capacity **TBC**, to be measured on named hardware; no transport performance claim |

| Offset | Bytes | Field / encoding |
|---:|---:|---|
| 0 | 4 | Segment ID |
| 4 | 2 | Frame sequence |
| 6 | 1 | Flags: bit 0 START segment; bit 1 END segment; bit 2 LAST fragment; others reserved |
| 7 | 1 | Reserved |
| 8 | 2 | Fragment offset in encoded packet |
| 10 | 2 | Total encoded packet bytes |
| 12 | remaining | Fragment bytes |

For data frames, END=0, total>0, fragment nonempty. All fragments of frame 0
carry START=1; other frames START=0. LAST=1 exactly when offset+payload length
matches total. Concatenate exact contiguous offsets, then decode one complete
packet. One frame at a time, ordered fragments; do not interleave segments/frames.

END is a separate header-only notification: END=1, LAST=1, START=0, offset=total=0;
frame sequence is the next sequence after the last encoded frame. Every segment
has at least one frame and exactly one END in normal operation. Control release,
mode switch or phone stop closes the current segment; OFF discards unsent audio
and permits only the empty END marker followed by an Input snapshot with streaming=0.
No queued audio gets flushed after OFF. On disconnection the phone closes the
segment as interrupted even if END never arrives.

Examples A0/A1: segment `0x12345678`, frame 0, synthetic 12-byte packet
`00 01 02 03 04 05 06 07 08 09 0a 0b` split for a 20-byte value budget.
A0 is 20 bytes, A1 is 16 bytes. These verify transport framing only; the synthetic
packet is not a codec test vector. A2 closes the segment, next sequence 1 (12 bytes):

```hex
78 56 34 12 00 00 01 00 00 00 0c 00 00 01 02 03 04 05 06 07
78 56 34 12 00 00 05 00 08 00 0c 00 08 09 0a 0b
78 56 34 12 01 00 06 00 00 00 00 00
```

| Condition | Phone / remote behavior |
|---|---|
| Missing fragment/frame, conflicting duplicate, invalid offset/total, unexpected segment or END | Phone drops the incomplete packet, marks the segment interrupted, clears arm, resets decoder and requests Input snapshot; no retransmission or silent splicing |
| Identical duplicate / stale completed frame | Ignore; never decode twice |
| Silence / missing final notification | Phone watchdog terminates stalled segments; draft timeout 1000 ms (**TBC**, proposed fail-closed setting, not a measured bound). No DTX in v1; encode each 20 ms interval |
| Transport loss or decoder error | Discard uncommitted segment text; retain already committed history with interruption status. No incomplete AI command executes; a new qualified trigger starts a new segment |
| Firmware backpressure / queue overflow | Stop source, drop queued audio, emit END when possible and streaming=0 snapshot; restart only after resync and a fresh deliberate trigger. Queue depth **TBD**, bounded, no indefinite backlog |
| Remote OFF | Stop acquisition/encoding and discard buffered audio immediately, clear arm and report OFF snapshot; phone rejects further data while off, clears provisional audio and stops this source only |

No packet-loss concealment, FEC or retransmission in this first transport profile;
source scoring sees interruption/dropouts rather than an apparently intact stream
([REQ-51]). Measurements, whisper comparison and comfort review ([REQ-53]) remain outstanding.

### MTU and connection scheduling

The phone/OS negotiates ATT MTU; firmware uses the actual negotiated value, never
a compiled assumption. Notification value budget is ATT_MTU−3; audio payload
budget is ATT_MTU−15 after this header. At ATT_MTU 23 that is 20 value bytes / 8
audio bytes, hence the examples above. The ATT limits and default MTU are from
[Bluetooth Core, ATT §§3.2.8, 3.4.7.1](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-62/out/en/host/attribute-protocol--att-.html).
Phone writes use the smaller of the OS-reported write-with-response limit and
the negotiated value budget, subtracting the 6-byte application header. Do not
rely on ATT long writes; this contract fragments at the application layer.

Firmware requests streaming connection parameters that follow
[Apple's connection-parameter guidance](https://developer.apple.com/library/archive/qa/qa1931/index.html);
iOS chooses the accepted interval. Exact requested/accepted intervals are **TBD**
until measured; no guaranteed interval, MTU or notification rate. Support the
small-MTU framing path even if it cannot sustain this codec profile: on inability
to keep up, stop visibly instead of accumulating latency or claiming success.
Recalculate fragment size on link changes; apply a new size at a frame boundary.

## Offline recording and deferred sync (capability bit 7)

```mermaid
stateDiagram-v2
  Idle --> Local: offline deliberate PTT / REC
  Live --> Local: disconnect detected, still physically recording
  Local --> Waiting: release / mode change / OFF / full
  Waiting --> Sync: compatible bonded phone, live idle
  Sync --> Waiting: live starts / disconnect
  Sync --> Deleted: phone confirms durable copy
```

**Owner decision, 2026-11-02:** transferred audio becomes phone history
text, labeled recorded offline with capture time. The remote performs no STT.
Neither capture mode creates authority: even AI-mode recordings never enter the
brain, a field, Send/Enter, or an execution queue automatically. A later explicit
person action uses current phone policy and destination. No target ID, field or
cached target label is stored as authority. This deferred behavior is an owner-decided
exception to ordinary mode routing [REQ-5]. The owner asked for offline audio storage; retention and encryption stay open under [REQ-56]/[Q-6].

### Capture boundaries

Local capture requires a previously enrolled owner bond. Revocation stops both live
and offline capture; fresh enrollment is needed before another recording. An explicit
incompatible-version result stops capture rather than selecting the offline fallback.
Phone pause/stop on a complete compatible session stays effective: absence of arm
alone does not select offline recording. Local controls still work while disconnected.

| Condition | Local behavior |
|---|---|
| No usable live session (disconnected or handshake incomplete), HOLD | Fresh PTT down starts local Opus acquisition without arm; PTT up ends it. No tap classification or lock on remote |
| No usable live session, CONTINUOUS | Deliberate selection of REC starts local capture until OFF, leaving REC, full or failure. Boot/reboot with REC selected needs leaving REC then selecting it again; HOLD needs release then fresh press |
| Link lost during live recording | At disconnect detection, continue acquisition into a new offline record if REC remains selected or HOLD PTT remains down. A phone-qualified lock with PTT up does not continue offline. Preserve mode at that boundary; no whole-segment replay |
| Transition loss | Already notified frames remain live only; in-flight notifications, incomplete live packets and queued pre-detection audio may be lost. Do not append them to offline storage. Start the offline encoder with the next complete 20 ms acquisition interval after detection; reset codec. Detection/encoding/flash gaps and first-word loss are **TBC**, not seamless recovery |
| Mode/capture position change | Finalize current record. Store mode per new record; in REC start a new record immediately after mode change; in HOLD require release then new press. No phone acknowledgement needed offline |
| Reconnect while locally recording | Finish locally under these rules; do not splice into a live segment or upload an open record. Live arming waits for release/fresh press or fresh REC selection and the normal handshake |
| Storage full / write failure | Stop, finalize durable prefix, show full/error and report state; never overwrite old audio. Reserve finalization space. After space is freed, require a fresh deliberate trigger |
| OFF | Immediately stop acquisition/encoding, discard volatile unsaved audio, preserve earlier durable frames and finalize without acquiring more. Cancel sync transfers, clear arm; no audio data transmission while OFF. Control/list/confirmation and progress may continue |

On transfer the phone rejects recordings shorter than 300 ms (fewer than 15 complete
20 ms frames) before STT: durably record a discarded-short disposition by ID, then
confirm deletion. No history text, action, or reconstruction of double-tap/lock.
Longer records are deferred transcription even if mode was AI. This draft disables
offline tap-lock; unresolved live double-tap rules [REQ-8] remain unchanged.
Example Eoffline, 14 bytes:

```hex
2b 00 00 00 fc 03 00 00 00 01 00 01 02 00
```

Eoffline is an event-0 snapshot at tick 1020, HOLD down, dictation, recording offline;
it does not synthesize a PTT edge or authorize capture on the phone.

### Persistent records, clock and integrity

A recording is one segment record, not an audio file containing multiple modes.
Split continuous capture before exported size would exceed u32; successor records
are separate history items. IDs are nonzero u64 counters durably allocated before
capture, never reused across reboot, deletion, reflashing or bond changes. Namespace
phone copies by enrolled remote identity plus recording ID. If identity/counter
continuity cannot be preserved after factory reset, require new enrollment identity.
Stop instead of wrapping counters. One allowed owner bond can sync; re-enrollment
never silently transfers a previous owner's records (explicit local erase required).

Use boot ID u32, durably incremented before each boot's capture, plus monotonic u64
milliseconds since boot (extended from any hardware counter). Input keeps its u32
clock unchanged. Clock request C1 supplies a sample of that boot/tick and phone UTC
Unix milliseconds: offset = UTC − tick, evaluated with signed arithmetic. Remote
accepts only current boot, tick not in future and sample age ≤10000 ms (**TBC** draft
freshness bound). G reports current boot/tick so the phone can sample near receipt;
BLE delay makes wall time approximate. Phone refreshes after reconnect; a new
sample doesn't change the times of earlier records. Snapshot offset at capture start; UTC start =
start tick + offset. Reject out-of-range dates. Without a sample this boot, UTC=0
and approximate flag=1; display unknown wall time with boot/tick, never invent UTC
from transfer time. Synced UTC is also an estimate; approximate flag remains 1.
StopWatch RTC availability/accuracy/persistence is **unverified** and unused here.

| Metadata offset | Bytes | Encoding |
|---:|---:|---|
| 0 | 8 | Recording ID |
| 8 | 4 | Boot ID |
| 12 | 8 | Capture start monotonic ms |
| 20 | 8 | Estimated UTC start ms; 0 unknown |
| 28 | 1 | Captured mode: 0 dictation, 1 AI |
| 29 | 1 | Flags: bit 0 approximate time (always 1 in this draft); bit 1 interrupted by power loss, full or write failure, or corrupt (Fetch and Confirm then return status 5); others zero |
| 30 | 4 | Exported stream bytes |
| 34 | 4 | Complete frame count; duration = count × 20 ms |
| 38 | 4 | CRC-32 of exported stream |

Exported stream is ordered frames: u16 packet length (1..Version/info maximum),
then exactly that many raw Opus bytes; no padding, END marker or per-frame sequence.
Same mono/16 kHz/20 ms profile as live. CRC-32 uses reflected polynomial 0xedb88320,
initial 0xffffffff, final XOR 0xffffffff (CRC-32/ISO-HDLC). Check lengths, frame
count and CRC before transcription/confirmation. CRC detects corruption, not attacks.
Example M, 42 bytes:

```hex
01 00 00 00 00 00 00 00 07 00 00 00 e8 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01 05 00 00 00 01 00 00 00 a0 dd 97 76
```
Example S, 5 bytes:

```hex
03 00 00 01 02
```

M describes record 1, boot 7, start 1000 ms, unknown UTC, dictation, approximate,
one frame and 5 exported bytes. S is its synthetic 3-byte packet with length prefix;
not an Opus decode vector and too short for transcription.

Firmware chooses filesystem and physical layout. Commit metadata and complete frames
with recoverable boundaries and integrity checks; a torn final packet/metadata update
cannot invalidate earlier committed frames or other records. After power loss, recover
the verified prefix, mark interrupted, recompute immutable export size/count/CRC;
discard empty records. Volatile tail is lost; durable commit cadence/loss bound **TBD**.
Exclude open records from listing/count. Finalized exports never change. Corrupt
records remain retained and visibly errored, never confirmed as successfully copied.
Deletion frees space only after durable phone confirmation; persist the deletion before
replying. Firmware may reserve space for journal/metadata; do not promise all flash.

Capacity estimate only: at an assumed **TBC** 24 kbit/s Opus and 50 frames/s,
length prefixes add 100 bytes/s: free usable bytes / (3000 + 100) ≈ seconds.
One hypothetical 1 MiB gives ≈338 s (5.6 min), excluding metadata, reserve and
filesystem overhead. This is arithmetic, not board capacity; bitrate/free flash and
actual capacity need measurement. G reports usable free/total bytes, not chip size.

### Sync framing and scheduling

All three new characteristics require the same bonded, authenticated encrypted
link; sync starts only after compatible Version/info and result/progress subscriptions.
Use the Phone state 6-byte fragment envelope on each: transaction u16 at 0,
logical length u16 at 2, offset u16 at 4, nonempty payload at 6. Logical request
length 1–21, result 2–512, progress 46. Apply the same contiguous assembly, replacement
and rejection rules; no ATT long writes. This is framing reuse, never Phone state
application. Result transaction echoes the request; one outstanding request, one reply.
Progress uses its own modulo-u16 sequence, starts 0 per connection. Disconnect clears
assemblies. Lost result/fragment: resubscribe/resync then repeat request with new
transaction; operations are idempotent. Do not reuse transaction IDs while a reply
can still be outstanding; reconnect before wrap. ATT write success only accepts the
request; R4 is the durable deletion acknowledgement.

| Request opcode | Exact logical layout (offset:bytes) |
|---|---|
| 1 Set clock | 0:1 opcode; 1:4 boot ID; 5:8 sampled tick; 13:8 corresponding UTC ms |
| 2 List next | 0:1 opcode; 1:8 cursor recording ID, 0 starts list; return smallest finalized ID greater than cursor |
| 3 Fetch | 0:1 opcode; 1:8 recording ID; 9:4 stream byte offset; 13:2 max bytes, 1–496 |
| 4 Confirm durable copy / delete | 0:1 opcode; 1:8 ID; 9:4 complete stream size; 13:4 CRC |

Every reply starts 0:1 echoed opcode, 1:1 status: 0 success, 1 list exhausted,
2 not found, 3 busy (capture/OFF), 4 invalid argument, 5 integrity/storage error.
Nonzero replies have exactly 2 bytes; status 1 only for List. Malformed envelope,
unknown opcode or malformed length gets ATT error, no operation. Error examples
use the same layout. Successful payloads:

| Reply | Exact logical layout |
|---|---|
| R1 Clock | 2 bytes only |
| R2 List entry | 2:42 metadata above; total 44 bytes. Advance cursor to returned ID; restart at 0 after reconnect and deduplicate by ID |
| R3 Fetch data | 2:8 ID; 10:4 requested offset; 14:2 returned byte count K; 16:K stream bytes. K=min(request max, size−offset). Offset=size returns K=0; offset>size invalid. Byte offsets may split a packet |
| R4 Confirmation | 2 bytes only; size/CRC must match finalized record before deletion |

Fetch finalized records only; list is a live ordered view, not a snapshot. New larger
IDs may appear on a subsequent pass; deletion can remove entries. Resume by ID and
first missing byte in a durably saved partial phone copy; verify metadata unchanged,
otherwise discard partial and refetch. Repeated bytes at the same offset must match.
Never stream sync bytes on Audio or decode them as live frames. A matching CRC alone
is insufficient: the phone checks full length/frame structure/count too. After complete
validation, durably save audio and metadata under the ID (or the short-discard
disposition), then C4. A phone crash/retry never creates another history item or STT
job for that ID. STT may run after deletion from the remote; phone retains durable
source until transcription succeeds or the person explicitly discards it. Keep failed
transcription visible for retry. No automatic AI/insertion follows STT.

Repeated C4 after deletion succeeds with R4 even after reconnect/reboot. IDs are never
reused, so an allocated ID with no stored record has already been deleted and needs no
per-record memory. A stored record with a mismatched size/CRC is invalid; an ID never
allocated is not found. A lost R4 thus never requires resending audio or guessing whether
the phone saved it, and deleted records cost no flash.

Live acquisition, Input and Phone state always have priority. Pause sync before a
new local/live segment starts; abandon any unsent result/progress fragments and let
the phone retry after capture. A capture-start Input snapshot cancels the phone's outstanding sync
request; the remote drops that reply. The next request starts a new transaction.
An in-flight ATT notification may complete, but no
further sync audio bytes are queued. Phone discards incomplete result assembly on
capture start. Fetch while recording or OFF returns busy; metadata/control can proceed
when they do not delay capture. No flash transfer competes with acquisition. Sync
never arms capture and never blocks a deliberate trigger.

Example C1, 21 bytes:

```hex
01 07 00 00 00 e8 03 00 00 00 00 00 00 00 68 e5 cf 8b 01 00 00
```

Example C2, 9 bytes:

```hex
02 00 00 00 00 00 00 00 00
```

Example C3, 15 bytes:

```hex
03 01 00 00 00 00 00 00 00 00 00 00 00 05 00
```

Example C4, 17 bytes:

```hex
04 01 00 00 00 00 00 00 00 05 00 00 00 a0 dd 97 76
```

Example R1, 2 bytes:

```hex
01 00
```

Example R2, 44 bytes:

```hex
02 00 01 00 00 00 00 00 00 00 07 00 00 00 e8 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01 05 00 00 00 01 00 00 00 a0 dd 97 76
```

Example R2end, 2 bytes:

```hex
02 01
```

Example R3, 21 bytes:

```hex
03 00 01 00 00 00 00 00 00 00 00 00 00 00 05 00 03 00 00 01 02
```

Example R4, 2 bytes:

```hex
04 00
```

Example R4repeat, 2 bytes:

```hex
04 00
```

Example Rbusy, 2 bytes:

```hex
03 03
```

C1 samples boot 7/tick 1000 at synthetic UTC 1700000000000. C2 starts listing;
C3 requests all 5 bytes of record 1; C4 confirms its size/CRC. R2/R3 refer to M/S;
R2end is exhausted, R4repeat is an already confirmed deletion, Rbusy defers fetch.
These are logical messages; wrap and split each to the actual value budget.
For example C2 in transaction 9 is one 15-byte write:

```hex
09 00 09 00 00 00 02 00 00 00 00 00 00 00 00
```

### Progress and screen states

Emit progress on subscription and state/capacity/transfer changes, coalescing during
capture to protect live timing. Phone may resubscribe for a fresh snapshot; no polling
command needed. Input is the compact state signal; streaming/offline bits are mutually exclusive.
While disconnected, retain current status locally and report it after subscription;
never queue old Input events. Progress logical layout:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 1 | Flags, identical to Input status bits 0–4 |
| 1 | 1 | Reserved |
| 2 | 4 | Finalized records waiting count |
| 6 | 8 | Usable free bytes |
| 14 | 8 | Usable total bytes (including free); free ≤ total |
| 22 | 8 | Most recent sync recording ID; 0 none this connection |
| 30 | 4 | Next stream offset emitted in latest fetch result; 0 before first byte |
| 34 | 4 | Current boot ID |
| 38 | 8 | Current monotonic ms sampled for this snapshot |

Offset is transport progress, never proof of durable receipt/deletion. On reconnect
it resets to zero; phone's durable partial copy determines resume. Current sync ID
can remain visible while paused; syncing bit is set only during active transfer.

Example G, 46 bytes:

```hex
08 00 01 00 00 00 00 00 10 00 00 00 00 00 00 00 20 00 00 00 00 00 01 00 00 00 00 00 00 00 05 00 00 00 07 00 00 00 e8 03 00 00 00 00 00 00
```

G: waiting=1, 1 MiB free of hypothetical 2 MiB usable, record 1 at offset 5,
boot 7/tick 1000, not actively syncing. Fragment the 46 bytes before notifying.

| Screen state | Source / meaning |
|---|---|
| Recording offline | Local capture bit 1; stored mode, no current destination claim |
| Storage full | Bit 2; capture stopped, old audio preserved; persists until capacity is available |
| Recordings waiting to send | Bit 3 plus waiting count; excludes open record |
| Syncing | Bit 4 plus ID/offset; paused on capture, disconnect or OFF |

States can coexist (e.g. offline recording with earlier records waiting); OFF hides
no waiting/full state. No UI layout is prescribed. Storage failure is a visible error,
not a false successful recording; local errors do not rely on receiving Phone state.

## Security and microphone safety

| Boundary | Draft behavior / evidence |
|---|---|
| Enrollment | Enter pairing locally on remote, choose remote on phone. Use LE Secure Connections with bonding and authenticated Numeric Comparison: compare the same number on both screens and explicitly confirm on each. Reject mismatch, timeout, Legacy Pairing and Just Works; no downgrade. [Bluetooth security architecture](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v6.3/out/en/architecture%2C-change-history%2C-and-conventions/architecture.html) describes Numeric Comparison's MITM protection. ESP-IDF/iOS UI interoperability is **unverified** |
| Reconnect / revoke | Restore encrypted authenticated bond before reads/writes/notifications, then resync. Revoke removes the allowed bond, disconnects and stops audio; require fresh local pairing. Pairing UI is separate from this application service |
| Untrusted remote | Buttons, timestamps, names, capabilities and `hw_mic_cut` are untrusted input. Bonding identifies the remote, not the human actor. No message supplies `authenticated_actor`, `activation_kind`, `approval_credential_class` or `granted_scope_id` |
| Policy | Phone trusted input/policy validates activation and grants. Buttons carry no approval authority; tier 1 still requires a separately authenticated approval. Policy gate denies remote-button approval for tier 3: action-specific phone Face ID/passcode remains required. Medium-risk button approval [Q-5] stays open and disabled in v1 |
| OFF / [REQ-49] | Only capture not OFF permits audio. Phone state cannot override OFF. A compliant final rig cuts microphone power in hardware independently of firmware; software stop is insufficient |
| StopWatch stand-in | Vendor documents a MEMS mic and ES8311; `PYG3 (PYB_AU_EN)` on the I2C GPIO expander controls codec + mic power. Firmware can change it, so the board cannot meet the independent hardware OFF rule as supplied; `hw_mic_cut=0`. [M5Stack board documentation](https://docs.m5stack.com/en/core/StopWatch) |
| Waveshare Proto 1 | Vendor establishes an onboard microphone, ES8311 codec and touch display. No independent physical OFF cut is established. Treat the supplied board as unable to meet [REQ-49], `hw_mic_cut=0`; exact mic power path, software power gating and behavior under reset/fault are **unverified**, not inferred from the StopWatch. [Waveshare board documentation](https://www.waveshare.com/wiki/ESP32-C6-Touch-LCD-1.69) |

**Prototype exception, granted by the owner on 2026-11-02.** Both supplied boards
fail the required hardware OFF guarantee, and the owner accepted that for these test
boards: the mic may stay powered, and OFF is a firmware stop of capture and audio only.
Boards report `hw_mic_cut=0`. The exception does not weaken [REQ-49] or AGENTS.md for
the final design, and it is not evidence of compliance.

**Offline prototype privacy limitation ([REQ-56], [REQ-58], [Q-6]).** Test-board
recordings are stored unencrypted in flash under this draft. ESP32 flash encryption
programs eFuses ([Espressif flash encryption guide](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/security/flash-encryption.html));
it is not enabled on these test boards per the task constraint, not a verified board
inspection. Bond encryption protects transfer, not physical flash access. Confirmed
delete is logical deletion, not guaranteed forensic erasure. Resolve encrypted storage,
consent, retention and secure deletion before release; temporary raw audio conflicts
with the proposed no-raw-audio default. OFF stops offline capture too; the existing
`hw_mic_cut=0` prototype exception is unchanged and grants no privacy exception.

## Open questions

| Item | Outstanding decision / verification |
|---|---|
| Prototype safety | Exception granted for test boards (above); the hardware OFF design for the final rig remains open |
| Trigger semantics | Shared double-tap window, short-tap precedence, lock/unlock and REC/PTT interaction; disable tap-lock until defined |
| Capture adapter | On branch `codex/feat-stt-engines`, not yet on this base: `CaptureSource.frames() -> AsyncStream<AudioFrame>`, 16 kHz Int16 PCM. That API has no way to signal an interrupted segment, which this contract's loss handling needs; the iOS side defines how to carry it |
| Mechanical contract | Binary schema/codegen and positive/negative interoperable fixtures; examples here verify layout only |
| Transport / codec | Bitrate, queue bound, timeout tuning, accepted MTU/interval, sustained throughput, background iOS behavior and Opus performance on both boards |
| Controls / hardware | Actual physical/virtual mapping, mic topology and independent OFF implementation; screen rendering barrier behavior on both boards |
| Enrollment | Numeric Comparison confirmation on both screens, revocation and bond reset on actual ESP-IDF/iOS builds |
| Authority | [Q-5] medium-risk approval authentication; no remote approval enabled by this draft |
| Product gate | [REQ-51]/[REQ-53] source-quality and whisper benchmarks, comfort, power and latency remain unverified |
| Offline bitrate / capacity | Measure configured Opus bitrate, usable flash, commit cadence, power-loss tail and recording capacity on both named boards; estimates above are unverified |
| Offline transfer | Measure sustained/background iPhone fetch throughput, resume and capture preemption at small/large MTU; no transfer-time promise |
| Flash wear | Measure write/erase cycles, journal overhead, wear distribution and exhaustion behavior under repeated recording/deletion |
| Encrypted storage | Resolve [REQ-56]/[REQ-58]/[Q-6] conflict, consent, retention, at-rest encryption/key provisioning and secure erase before release |
| Deferred history | Confirm the short-discard disposition and separate history items at segment boundaries in use; offline-to-history text itself is decided |
