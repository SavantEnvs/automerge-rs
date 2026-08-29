/* Build-time LeakSanitizer off-switch: ASan stays fully active, only leak detection is disabled. */
int __lsan_is_turned_off(void) { return 1; }
