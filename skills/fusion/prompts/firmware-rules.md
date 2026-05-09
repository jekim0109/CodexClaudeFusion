FIRMWARE-SPECIFIC REVIEW RULES (active when fusion.firmware = true)

In addition to the general review rules above, also check the following.
When you report a firmware-specific issue, prepend the category to the
severity label, e.g.:
   BLOCKER (A.ISR): src/foo.c:42 — ...
   MAJOR (B.VOL):   src/bar.c:17 — ...

A. ISR safety and race conditions

- ISR must not block or sleep. No busy-wait beyond a few cycles, no
  malloc/free, no mutex acquire on a lock that mainline may hold,
  no printf or other I/O that may block. → BLOCKER if found.
- Long ISR work: heavy computation or long loops in ISR context →
  MAJOR (consider deferred work via a flag + main loop or task).
- ISR-shared state: any variable read or written by both ISR and main
  must be (a) qualified `volatile` AND (b) accessed atomically — single
  32-bit load/store on Cortex-M, or wrapped in a critical section.
  Missing either → MAJOR.
- Memory ordering: when DMA buffers or peripheral state cross ISR↔main,
  flag missing memory barrier (DMB/DSB/ISB) or compiler barrier where
  ordering is required → MAJOR.
- Critical sections: must be short and balanced (enable matches every
  disable). Early return between disable and enable → BLOCKER.
- ISR re-entrancy: nested same-vector calls without explicit guard →
  BLOCKER if state is shared.

B. Volatile correctness

- Hardware register access (memory-mapped peripherals) MUST use
  `volatile`. Missing → BLOCKER (read/write may be optimized away).
- ISR-shared variables (see A above) — missing `volatile` → MAJOR.
- `volatile` is NOT atomic. Flag any use of `volatile` as a substitute
  for synchronization → MAJOR.
- `volatile T*` vs `T* volatile` distinction: confirm declaration
  matches the intent (pointee mutable vs pointer mutable). Mismatch
  → MAJOR.
- Redundant volatile (local non-shared variable, etc.) → MINOR.

Style preferences alone (e.g. naming, indentation) are NOT grounds for
REVISE — the base rules above already say so. Only flag firmware
concerns when the diff plausibly creates the hazard.
