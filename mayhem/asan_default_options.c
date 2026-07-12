/* Baked-in ASan defaults for the fuzz target (linked into /mayhem/delta only).
 * delta is an allocate-and-exit batch CLI: exit-time leak reports would flag every
 * input, so leak detection is off by default while ASan's memory-safety checks stay
 * on and halting. Mayhem owns the runtime ASAN_OPTIONS; these defaults compose with
 * (and are overridden by) it. */
const char *__asan_default_options(void) { return "detect_leaks=0"; }
