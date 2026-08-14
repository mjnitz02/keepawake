/*
 * keepawake-nudge: the two things "nudge" mode needs from the window server.
 *
 *   keepawake-nudge idle             print whole seconds since the last HID event
 *   keepawake-nudge nudge            move the cursor 1px and back, print the new idle
 *   keepawake-nudge check            exit 0 if Accessibility is granted, 1 if not
 *   keepawake-nudge check --prompt   same, but ask macOS to show the grant dialog
 *
 * Why a compiled helper instead of a line of shell:
 *
 *   The screen saver starts on HID idle time, the clock that only real input
 *   events reset. IOKit power assertions (caffeinate -d, -i, -m, -s, -u, and
 *   every app built on them) move the display-sleep and system-sleep timers
 *   instead. Those are different clocks. That is how a Mac can sit with several
 *   assertions held and still run its screen saver exactly on schedule.
 *
 *   Nothing in shell resets the HID clock. Synthesizing an input event does,
 *   and that needs CoreGraphics.
 *
 * Posting events requires Accessibility permission for THIS binary. Without it
 * CGEventPost silently does nothing, no error, no signal. So the honest test of
 * whether a nudge landed is "did the idle time drop", not what
 * AXIsProcessTrusted claims. `nudge` prints the post-nudge idle for exactly
 * that reason: the caller can check the outcome rather than trust the API.
 *
 * Build:
 *   cc -O2 -Wall -o keepawake-nudge keepawake-nudge.c -framework ApplicationServices
 */

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static double idle_seconds(void)
{
	return CGEventSourceSecondsSinceLastEventType(
		kCGEventSourceStateHIDSystemState, kCGAnyInputEventType);
}

static bool accessibility_granted(bool prompt)
{
	if (!prompt)
		return AXIsProcessTrusted();

	const void *keys[] = { kAXTrustedCheckOptionPrompt };
	const void *vals[] = { kCFBooleanTrue };
	CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
						  &kCFTypeDictionaryKeyCallBacks,
						  &kCFTypeDictionaryValueCallBacks);
	bool ok = AXIsProcessTrustedWithOptions(opts);
	if (opts)
		CFRelease(opts);
	return ok;
}

static void post_move(CGPoint p)
{
	CGEventRef ev = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p,
						kCGMouseButtonLeft);
	if (!ev)
		return;
	CGEventPost(kCGHIDEventTap, ev);
	CFRelease(ev);
}

/*
 * One pixel over and straight back, so the cursor ends exactly where it
 * started. A user watching the screen sees nothing; the HID clock sees input.
 */
static int nudge(void)
{
	CGEventRef probe = CGEventCreate(NULL);
	if (!probe) {
		fprintf(stderr, "keepawake-nudge: could not read cursor position\n");
		return 1;
	}
	CGPoint here = CGEventGetLocation(probe);
	CFRelease(probe);

	/*
	 * Step toward the interior. A cursor parked hard against the left edge
	 * would have a -1 move clamped by the window server, and the return
	 * move would then leave it one pixel off where the user left it.
	 */
	CGPoint away = here;
	away.x += (here.x >= 1.0) ? -1.0 : 1.0;

	post_move(away);
	usleep(50000);
	post_move(here);
	return 0;
}

static int usage(void)
{
	fprintf(stderr,
		"usage: keepawake-nudge <idle|nudge|check [--prompt]>\n");
	return 64;
}

int main(int argc, char **argv)
{
	if (argc < 2)
		return usage();

	if (strcmp(argv[1], "idle") == 0) {
		printf("%.0f\n", idle_seconds());
		return 0;
	}

	if (strcmp(argv[1], "nudge") == 0) {
		int rc = nudge();
		if (rc != 0)
			return rc;
		/* Let the event settle before reporting what it achieved. */
		usleep(50000);
		printf("%.0f\n", idle_seconds());
		return 0;
	}

	if (strcmp(argv[1], "check") == 0) {
		bool prompt = (argc > 2 && strcmp(argv[2], "--prompt") == 0);
		bool ok = accessibility_granted(prompt);
		printf("%s\n", ok ? "granted" : "denied");
		return ok ? 0 : 1;
	}

	return usage();
}
