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

int main(void)
{
	const Window app = 10, menu = 20, other = 30;

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
