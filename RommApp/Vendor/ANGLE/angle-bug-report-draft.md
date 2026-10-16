# Draft: ANGLE bug report (not yet filed upstream)

## Title
Metal: client vertex array streaming hazard corrupts draws on Apple
GPUs; existing flushAfterStreamVertexData workaround fixes it but is
gated to AMD Bronze drivers only

## Environment
- ANGLE tip-of-tree (tested at 4d8cb8a1a37c, 2026-08-18), Metal backend
- Reproduced on: Apple M4 (macOS 26.6.1), Apple TV 4K 3rd gen A15
  (tvOS 26), iPhone Air (iOS 26)
- Frontend: GLES 3.0 context, offscreen FBO rendering

## Summary
An application that draws many primitives per render pass using client
memory vertex arrays (no VBO) can have a draw consume overwritten
vertex data: the pixels render as per-pixel garbage (in our case a
polygon of chromatic noise). The corruption is deterministic for a
given command stream, is unaffected by CPU-side timing changes, and
disappears only when a full flush-and-wait is inserted per draw.

ANGLE already contains a targeted workaround for what appears to be
this exact hazard: Feature "flushAfterStreamVertexData"
(VertexArrayMtl.mm, flushCommandBuffer(WaitUntilScheduled) after each
StreamVertexData; the in-code comment notes NoWait is not sufficient,
matching our observations). It is enabled only when
isAMDBronzeDriver() (DisplayMtl.mm:1312). Enabling the feature via
ANGLE_FEATURE_OVERRIDES_ENABLED on Apple-GPU devices completely
eliminates the corruption on all three devices above.

## Reproduction
Emulator workload (mupen64plus-next / GLideN64 in unbuffered client
array mode) driving ~300 client-array draws per frame at 320x240.
Deterministic: the same frame of an attract-mode sequence corrupts on
every run (M4: frame ~1650 of Hydro Thunder (USA) attract; A15: ~1747).
We can supply a headless CLI harness (libretro core + pbuffer context)
that reproduces in ~10 seconds and a per-frame chromatic-noise detector
that flags the corrupt frames mechanically. A minimal standalone GLES
repro (many client-array draws of small triangle fans per pass, varying
data per draw) should be straightforward from the above description;
we are happy to help construct one.

## Evidence that it is the streaming pool
- Time profiler shows the draw path:
  ContextMtl::setupDrawImpl -> VertexArrayMtl::updateClientAttribs ->
  StreamVertexData -> mtl::BufferPool::allocateAndMap (with heavy
  CommandQueue::ensureResourceReadyForCPU / waitUntilCompleted).
- Suppression matrix (all on-device, deterministic frame):
  - glReadPixels(1px) after EVERY draw: corruption gone
  - glFlush after every draw: still corrupt (matches the workaround's
    "NoWait does not have the needed effect" comment)
  - full glFinish before every glTexSubImage2D: still corrupt
  - sync every 8th or 64th draw: still corrupt
  - sync on program change / texture change: still corrupt
  - flushAfterStreamVertexData enabled: corruption gone
- Guarding BufferPool::allocate's free-list reuse with
  hasPendingWorks() did NOT fix it, so the stale read appears to be
  within-buffer (offset reuse) rather than whole-buffer reuse.

## Root cause (traced)
BufferPool hands a retired stream buffer back to the CPU while draws
recorded in the still-open render pass reference its previous contents.
Instrumentation showed the same MTLBuffer remapped at offset 0 for
consecutive allocations with isBeingUsedByGPU() == false, and
CRC-at-flush verification proved the slices' bytes were rewritten
between streaming and submission, exactly correlated with the corrupt
frames. Two adjacent hazards worth noting: the max-buffers recycle path
in allocateNewBuffer() calls flushCommandBuffer(NoWait) +
ensureResourceReadyForCPU(), but a NoWait flush cannot commit an open
pass, so the wait loop has nothing to drain (its own trailing ASSERT
documents the case, and release builds compile it out).

## Suggested fix (tested)
Stamp the retiring buffer with the current command buffer's queue
serial in BufferPool::finalizePendingBuffer():

    mBuffer->setUsedByCommandBufferWithQueueSerial(
        contextMtl->getCommandBuffer().getQueueSerial(), false, true);

(getCommandBuffer() is a one-line accessor added to ContextMtl.) The
free list then quarantines the buffer until the open pass completes and
reuse resumes naturally. Measured on the reproduction: corruption
eliminated; frame rate within noise of baseline (57.5 vs 58.5 fps on
Apple TV A15; run-time mean 8.92 ms vs 9.40 baseline), versus the
flushAfterStreamVertexData workaround's 41.2 fps / 2.2x frame cost on
the same content. Happy to submit this as a CL with the reproduction.
