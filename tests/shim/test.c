/* Drives the shim through the fake libX11. Prints one line per failed check
 * and exits with their number. Run with LD_PRELOAD set to the shim. */
#include <stdio.h>
#include <string.h>
#include <X11/Xlib.h>

extern unsigned fake_pointer[], fake_pointer_pixel;
void fake_queue(const XEvent* event);
int fake_waiting(void);

struct image { unsigned version, size, width, height, xhot, yhot, delay; unsigned* pixels; };
Cursor XcursorImageLoadCursor(Display* display, const struct image* image);

/* A pointer picture of one colour; the first pixel X gets says what was done to it. */
static void pointer(unsigned side, unsigned hot)
{
	static unsigned pixels[64 * 64];
	struct image image = { 0 };
	for (unsigned i = 0; i < side * side; i++) pixels[i] = (i % 2) ? 0xff204060 : 0xff406080;
	image.width = image.height = side;
	image.xhot = image.yhot = hot;
	image.pixels = pixels;
	XcursorImageLoadCursor(NULL, &image);
}

static int failed;

static void check(const char* what, long actual, long expected)
{
	if (actual == expected) return;
	printf("%s: expected %ld, got %ld\n", what, expected, actual);
	failed++;
}

/* The type the client sees for one key event: KeyPress/KeyRelease when it
 * got through, something else when it was withheld. */
static int key(int type, unsigned keycode, unsigned state)
{
	XEvent event = { 0 };
	event.type = type;
	event.xkey.type = type;
	event.xkey.keycode = keycode;
	event.xkey.state = state;
	fake_queue(&event);
	XNextEvent(NULL, &event);
	return event.type;
}

/* Every event the client gets for one key event, written out in order:
 * +code a press, -code a release, xcode withheld. */
static void sequence(int type, unsigned keycode, unsigned state, char* out, size_t size)
{
	XEvent event = { 0 };
	event.type = type;
	event.xkey.type = type;
	event.xkey.keycode = keycode;
	event.xkey.state = state;
	event.xkey.serial = 500 + keycode;
	fake_queue(&event);
	size_t used = 0;
	out[0] = 0;
	do
	{
		XNextEvent(NULL, &event);
		const char* name = event.type == KeyPress ? "+" : event.type == KeyRelease ? "-" : "x";
		used += (size_t)snprintf(out + used, size - used, "%s%s%u", used ? " " : "", name,
		                         event.xkey.keycode);
	} while (fake_waiting() && used < size);
}

static void check_sequence(const char* what, int type, unsigned keycode, unsigned state,
                           const char* expected)
{
	char actual[128];
	sequence(type, keycode, state, actual, sizeof(actual));
	if (!strcmp(actual, expected)) return;
	printf("%s: expected %s, got %s\n", what, expected, actual);
	failed++;
}

static void focus_out(void)
{
	XEvent event = { 0 };
	event.type = FocusOut;
	fake_queue(&event);
	XNextEvent(NULL, &event);
}

static unsigned held(void)
{
	Window w;
	int i;
	unsigned mask = 0;
	XQueryPointer(NULL, 0, &w, &w, &i, &i, &i, &i, &mask);
	return mask;
}

int main(int argc, char** argv)
{
	enum { SUPER = 133, TWO = 11, Y = 29, C = 54, CTRL = 37, SHIFT = 50 };
	(void)argv;

	if (argc > 1) /* with WINAPP_SUPER=windows and WINAPP_POINTER=200 */
	{
		pointer(64, 20);
		check("on a 200% monitor the pointer is halved", fake_pointer[0] * 1000 + fake_pointer[1], 32032);
		check("...and where it points with it", fake_pointer[2] * 1000 + fake_pointer[3], 10010);
		check("...each pixel the average of those it replaces", fake_pointer_pixel, 0xff305070);
		check("Super reaches Windows when asked for", key(KeyPress, SUPER, 0), KeyPress);
		check("...and so does a key pressed with it", key(KeyPress, Y, Mod4Mask), KeyPress);
		check("...and it is reported held", held() & Mod4Mask, Mod4Mask);
		return failed;
	}

	check("ordinary typing goes through", key(KeyPress, Y, 0), KeyPress);
	check("...release too", key(KeyRelease, Y, 0), KeyRelease);
	(void)key(KeyPress, SHIFT, 0);
	check("with Shift held it still goes through", key(KeyPress, Y, ShiftMask), KeyPress);
	(void)key(KeyRelease, Y, ShiftMask);
	(void)key(KeyRelease, SHIFT, ShiftMask);
	check("the Super press is withheld", key(KeyPress, SUPER, 0) != KeyPress, 1);
	check("a key pressed while Super is down is withheld", key(KeyPress, Y, Mod4Mask) != KeyPress, 1);
	check("...its release too, even after Super is up", key(KeyRelease, Y, 0) != KeyRelease, 1);
	check("the Super release is withheld", key(KeyRelease, SUPER, Mod4Mask) != KeyRelease, 1);
	check("typing works again afterwards", key(KeyPress, Y, 0), KeyPress);
	check("...release too", key(KeyRelease, Y, 0), KeyRelease);
	/* arriving with Super already down: only its release is ever seen */
	check("a Super release with no press is withheld", key(KeyRelease, SUPER, Mod4Mask) != KeyRelease, 1);
	check("Super is not reported as held", held(), ShiftMask | Mod2Mask);
	/* a key held down from before Super was pressed keeps repeating in Windows */
	(void)key(KeyPress, Y, 0);
	check("a key already down repeats through Super", key(KeyPress, Y, Mod4Mask), KeyPress);
	check("...and its release goes through", key(KeyRelease, Y, Mod4Mask), KeyRelease);
	/* Super+2 changes workspace: the 2 is withheld and its release goes elsewhere */
	(void)key(KeyPress, SUPER, 0);
	(void)key(KeyPress, TWO, Mod4Mask);
	focus_out();
	check("a key whose release never came is not stuck withheld", key(KeyPress, TWO, 0), KeyPress);
	check("...its release goes through", key(KeyRelease, TWO, 0), KeyRelease);
	/* focus lost with a key down: a later Super press of it is still withheld */
	(void)key(KeyPress, Y, 0);
	focus_out();
	check("a key down when the focus left is not taken for a repeat", key(KeyPress, Y, Mod4Mask) != KeyPress, 1);
	(void)key(KeyRelease, Y, Mod4Mask);

	/* Omarchy's Super+C: Super goes down, then the desktop sends C saying
	 * Ctrl is held, with no Ctrl key; with Super's bit in the state or not */
	(void)key(KeyPress, SUPER, 0);
	check_sequence("the desktop's Ctrl+C reaches Windows with a Ctrl press", KeyPress, C, ControlMask, "+37 +54");
	check_sequence("...and the Ctrl is let go after the C", KeyRelease, C, ControlMask, "-54 -37");
	check_sequence("...also when the state still says Super", KeyPress, C, ControlMask | Mod4Mask, "+37 +54");
	check_sequence("...its release too", KeyRelease, C, Mod4Mask, "-54 -37");
	check_sequence("Super itself is still withheld", KeyRelease, SUPER, Mod4Mask, "x133");
	/* Ctrl+Shift+C from the desktop: both pressed in order */
	check_sequence("a chord with two modifiers presses both", KeyPress, C, ControlMask | ShiftMask, "+37 +50 +54");
	check_sequence("...and lets go of both", KeyRelease, C, ControlMask | ShiftMask, "-54 -50 -37");
	/* Ctrl+C typed by hand: nothing added */
	(void)key(KeyPress, CTRL, 0);
	check_sequence("Ctrl+C by hand is left alone", KeyPress, C, ControlMask, "+54");
	check_sequence("...its release too", KeyRelease, C, ControlMask, "-54");
	(void)key(KeyRelease, CTRL, ControlMask);
	/* Super+Ctrl+C by hand: a Super shortcut, withheld */
	(void)key(KeyPress, SUPER, 0);
	(void)key(KeyPress, CTRL, Mod4Mask);
	check_sequence("Super+Ctrl+C by hand is withheld", KeyPress, C, Mod4Mask | ControlMask, "x54");
	check_sequence("...its release too", KeyRelease, C, Mod4Mask | ControlMask, "x54");
	(void)key(KeyRelease, CTRL, Mod4Mask | ControlMask);
	(void)key(KeyRelease, SUPER, Mod4Mask);
	/* Shift found held when the window got the focus: Shift+C is typing */
	focus_out();
	(void)held();
	check_sequence("a modifier held on arriving is not pressed again", KeyPress, C, ShiftMask, "+54");
	(void)key(KeyRelease, C, ShiftMask);
	(void)key(KeyRelease, SHIFT, ShiftMask);

	pointer(64, 20);
	check("without a monitor scale the pointer is left alone", fake_pointer[0] * 1000 + fake_pointer[2], 64020);

	return failed;
}
