/* A stand-in for libX11: just the calls the shim wraps, recording what
 * reaches them, so the shim can be tested without an X server. */
#include <string.h>
#include <X11/Xlib.h>

Atom fake_last_property, fake_last_value;
int fake_mapped[64];                        /* by window id */
unsigned fake_pointer[4], fake_pointer_pixel; /* width, height, xhot, yhot; its first pixel */
static XEvent queue[8], back[8];
static int queued, taken, backs;

void fake_queue(const XEvent* event)
{
	if (taken == queued) taken = queued = 0;
	queue[queued++] = *event;
}

Atom XInternAtom(Display* display, const char* name, Bool only_if_exists)
{
	(void)display;
	(void)only_if_exists;
	if (!strcmp(name, "_NET_WM_WINDOW_TYPE")) return 100;
	if (!strcmp(name, "_NET_WM_WINDOW_TYPE_DIALOG")) return 101;
	if (!strcmp(name, "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU")) return 102;
	if (!strcmp(name, "_NET_WM_WINDOW_TYPE_NORMAL")) return 103;
	return 1;
}

int XChangeWindowAttributes(Display* display, Window window, unsigned long mask,
                            XSetWindowAttributes* attributes)
{
	(void)display; (void)window; (void)mask; (void)attributes;
	return 1;
}

int XChangeProperty(Display* display, Window window, Atom property, Atom type, int format,
                    int mode, const unsigned char* data, int nelements)
{
	(void)display; (void)window; (void)type; (void)mode;
	fake_last_property = property;
	fake_last_value = (format == 32 && nelements == 1) ? *(const Atom*)data : 0;
	return 1;
}

int XNextEvent(Display* display, XEvent* event)
{
	(void)display;
	if (backs)
		*event = back[--backs];
	else
		*event = queue[taken++];
	return 0;
}

int XPutBackEvent(Display* display, XEvent* event)
{
	(void)display;
	back[backs++] = *event;
	return 0;
}

int fake_waiting(void)
{
	return backs + queued - taken;
}

KeyCode XKeysymToKeycode(Display* display, KeySym symbol)
{
	(void)display;
	if (symbol == 0xffe3) return 37; /* Control_L */
	if (symbol == 0xffe1) return 50; /* Shift_L */
	if (symbol == 0xffe9) return 64; /* Alt_L */
	return 0;
}

Bool XQueryPointer(Display* display, Window window, Window* root, Window* child, int* root_x,
                   int* root_y, int* x, int* y, unsigned int* mask)
{
	(void)display; (void)window; (void)root; (void)child;
	(void)root_x; (void)root_y; (void)x; (void)y;
	*mask = ShiftMask | Mod2Mask | Mod4Mask; /* Shift, Num Lock and Super held */
	return True;
}

KeySym XLookupKeysym(XKeyEvent* key, int index)
{
	(void)index;
	if (key->keycode == 133) return 0xffeb; /* Super_L */
	if (key->keycode == 134) return 0xffec; /* Super_R */
	if (key->keycode == 37) return 0xffe3;  /* Control_L */
	if (key->keycode == 50) return 0xffe1;  /* Shift_L */
	if (key->keycode == 64) return 0xffe9;  /* Alt_L */
	return 0x61;                            /* any other key */
}

int XDestroyWindow(Display* display, Window window)
{
	(void)display; (void)window;
	return 1;
}

Window XCreateWindow(Display* display, Window parent, int x, int y, unsigned int width,
                     unsigned int height, unsigned int border, int depth, unsigned int class,
                     Visual* visual, unsigned long mask, XSetWindowAttributes* attributes)
{
	static Window next = 40;
	(void)display; (void)parent; (void)x; (void)y; (void)width; (void)height; (void)border;
	(void)depth; (void)class; (void)visual; (void)mask; (void)attributes;
	return next++;
}

int XMapWindow(Display* display, Window window)
{
	(void)display;
	fake_mapped[window] = 1;
	return 1;
}

int XUnmapWindow(Display* display, Window window)
{
	(void)display;
	fake_mapped[window] = 0;
	return 1;
}

int XResizeWindow(Display* display, Window window, unsigned int width, unsigned int height)
{
	(void)display; (void)window; (void)width; (void)height;
	return 1;
}

int XMoveResizeWindow(Display* display, Window window, int x, int y, unsigned int width,
                      unsigned int height)
{
	(void)display; (void)window; (void)x; (void)y; (void)width; (void)height;
	return 1;
}

/* libXcursor's call, with its XcursorImage */
struct image { unsigned version, size, width, height, xhot, yhot, delay; unsigned* pixels; };

Cursor XcursorImageLoadCursor(Display* display, const struct image* image)
{
	(void)display;
	fake_pointer[0] = image->width;
	fake_pointer[1] = image->height;
	fake_pointer[2] = image->xhot;
	fake_pointer[3] = image->yhot;
	fake_pointer_pixel = image->pixels[0];
	return 7;
}
