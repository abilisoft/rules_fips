extern void __stack_chk_fail(void) __attribute__((noreturn));

void __attribute__((visibility("hidden"))) __stack_chk_fail_local(void) {
    __stack_chk_fail();
}
