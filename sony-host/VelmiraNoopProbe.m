// Minimal dyld probe: intentionally does not call UIKit, Swift, PSN, or Sony symbols.
// Used to test whether merely loading one additional correctly signed iOS dylib
// prevents Sony Remote Play from launching.
__attribute__((constructor)) static void velmira_probe_load(void) {
    __asm__ volatile("" ::: "memory");
}
