/*
 * screen_state — reports display power and screen lock state.
 * Used by the wellness-coach idle sampler.
 *
 * Output: "display=on,locked=0" or "display=off,locked=1"
 *
 * Build: cc -O2 -framework CoreGraphics -framework CoreFoundation screen_state.c -o screen_state
 */
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

int main(void) {
    CGDirectDisplayID d = CGMainDisplayID();
    if (d == kCGNullDirectDisplay) {
        fprintf(stderr, "No display found\n");
        return 1;
    }
    int asleep = CGDisplayIsAsleep(d) != 0;

    int locked = 0;
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (session) {
        CFBooleanRef val = CFDictionaryGetValue(session, CFSTR("CGSSessionScreenIsLocked"));
        if (val)
            locked = CFBooleanGetValue(val);
        CFRelease(session);
    }

    printf("display=%s,locked=%d\n", asleep ? "off" : "on", locked);
    return 0;
}
