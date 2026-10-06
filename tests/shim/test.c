/* Drives the shim through the fake libX11. Prints one line per failed check
 * and exits with their number. Run with LD_PRELOAD set to the shim. */
#include <stdio.h>
#include <X11/Xlib.h>

extern Atom fake_last_value;
void fake_queue(const XEvent* event);

enum { WINDOW_TYPE = 100, DIALOG = 101, DROPDOWN_MENU = 102, NORMAL = 103 };
static int failed;

static void check(const char* what, long actual, long expected)
{
	if (actual == expected) return;
	printf("%s: expected %ld, got %ld\n", what, expected, actual);
	failed++;
}

static Atom set_type(Window window, Atom value)
{
	XChangeProperty(NULL, window, WINDOW_TYPE, 4, 32, PropModeReplace, (unsigned char*)&value, 1);
	return fake_last_value;
}

static void override_redirect(Window window, Bool on)
{
	XSetWindowAttributes attributes = { 0 };
	attributes.override_redirect = on;
	XChangeWindowAttributes(NULL, window, CWOverrideRedirect, &attributes);
}

static int next_type(Window window, Bool flagged)
{
	XEvent event = { 0 };
	event.type = ConfigureNotify;
	event.xconfigure.window = window;
	event.xconfigure.override_redirect = flagged;
	fake_queue(&event);
	XNextEvent(NULL, &event);
	return event.type;
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
	const Window app = 10, menu = 20, other = 30;
	enum { SUPER = 133, TWO = 11, Y = 29 };
	(void)argv;

	if (argc > 1) /* with WINAPP_SUPER=windows: everything goes through */
	{
		check("Super reaches Windows when asked for", key(KeyPress, SUPER, 0), KeyPress);
		check("...and so does a key pressed with it", key(KeyPress, Y, Mod4Mask), KeyPress);
		check("...and it is reported held", held() & Mod4Mask, Mod4Mask);
		return failed;
	}

	check("ordinary typing goes through", key(KeyPress, Y, 0), KeyPress);
	check("...release too", key(KeyRelease, Y, 0), KeyRelease);
	check("with Shift held it still goes through", key(KeyPress, Y, ShiftMask), KeyPress);
	(void)key(KeyRelease, Y, ShiftMask);
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

	check("an ordinary window keeps its dialog type", set_type(app, DIALOG), DIALOG);
	check("an ordinary window's geometry events pass", next_type(app, False), ConfigureNotify);

	override_redirect(menu, True);
	check("an unmanaged dialog becomes a menu, which is not focused", set_type(menu, DIALOG), DROPDOWN_MENU);
	check("...and only the dialog type is touched", set_type(menu, NORMAL), NORMAL);
	check("...and other windows are not affected", set_type(app, DIALOG), DIALOG);
	check("an unmanaged window's geometry events are withheld", next_type(menu, True) != ConfigureNotify, 1);
	check("...also when only the event says it is unmanaged", next_type(other, True) != ConfigureNotify, 1);
	check("...also when only the shim knows it is", next_type(menu, False) != ConfigureNotify, 1);

	override_redirect(menu, False);
	check("a window that becomes managed again is left alone", set_type(menu, DIALOG), DIALOG);
	check("...its geometry events too", next_type(menu, False), ConfigureNotify);

	override_redirect(menu, True);
	XDestroyWindow(NULL, menu);
	check("a destroyed window is forgotten", set_type(menu, DIALOG), DIALOG);

	return failed;
}
