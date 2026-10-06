/*
 * winapp-xshim: corrections to how FreeRDP's X11 client (xfreerdp) behaves on
 * a tiling Wayland desktop. winapp loads it into the client with LD_PRELOAD;
 * nothing else is affected. There are two: what the client does to Windows'
 * helper windows, and what it does with the Super key.
 *
 * --- Helper windows ---
 *
 * Windows programs keep small helper windows around that the user never
 * sees or touches: the hidden windows of an embedded Internet Explorer
 * control, pseudo-console windows, and also every classic menu and tooltip.
 * xfreerdp shows them as override-redirect X11 windows, which is right, but
 * then treats them like windows the user manages:
 *
 * 1. It labels them _NET_WM_WINDOW_TYPE_DIALOG. A Wayland compositor running
 *    X11 clients (Hyprland here) gives keyboard focus to override-redirect
 *    windows of that type, and xfreerdp answers focus by telling Windows to
 *    activate the helper window.
 *
 * 2. It reports whatever geometry the compositor gives them back to Windows
 *    as the user having moved or resized the window. Hyprland does not leave
 *    a window smaller than 20 pixels, and when it scales X11 clients it also
 *    rounds geometry by a pixel. So a helper window that Windows keeps at 0x0
 *    is resized, on the Windows side, to 20x20 (21x21 at a fractional scale),
 *    and a menu can come back a pixel wider than it was.
 *
 * A program does not expect either to happen to a window it hides. CorelDRAW's
 * welcome screen, or any program with an Internet Explorer control, answers by
 * spinning its UI thread: the window turns white, "Not Responding", for good.
 * It happens the moment the resize is relayed, which can be at start-up or
 * minutes later, when some other window opens.
 *
 * So, for override-redirect windows only: the type becomes DROPDOWN_MENU,
 * which is what xfreerdp itself first picks for them and which compositors do
 * not focus, and geometry notifications are dropped, since Windows alone
 * decides where such a window is. Ordinary windows are left exactly as they are.
 *
 * --- The Super key ---
 *
 * On Omarchy every Super shortcut belongs to the desktop: Super+2 changes
 * workspace, Super+W closes a window. The compositor still hands the Super
 * press itself to the focused window, xfreerdp forwards it, and when the
 * shortcut takes the focus away xfreerdp releases it again. Windows sees its
 * Windows key tapped and opens the Start menu, which is waiting there on the
 * way back. A Super shortcut the desktop does not use would arrive in Windows
 * as a bare letter.
 *
 * So Super is withheld from the client, together with any key pressed while
 * it is down, and is never reported as held. WINAPP_SUPER=windows in the
 * environment turns this off.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>

#define MAX_WINDOWS 4096

static Window unmanaged[MAX_WINDOWS]; /* override-redirect windows of this client */
static int count;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

/* Where a window is in the list, or -1. Called with the lock held. */
static int find(Window window)
{
	for (int i = 0; i < count; i++)
	{
		if (unmanaged[i] == window)
			return i;
	}
	return -1;
}

static int is_unmanaged(Window window)
{
	pthread_mutex_lock(&lock);
	const int found = find(window) >= 0;
	pthread_mutex_unlock(&lock);
	return found;
}

static void set_unmanaged(Window window, int on)
{
	pthread_mutex_lock(&lock);
	const int at = find(window);
	if (on && at < 0 && count < MAX_WINDOWS)
		unmanaged[count++] = window;
	else if (!on && at >= 0)
		unmanaged[at] = unmanaged[--count];
	pthread_mutex_unlock(&lock);
}

int XChangeWindowAttributes(Display* display, Window window, unsigned long mask,
                            XSetWindowAttributes* attributes)
{
	static int (*real)(Display*, Window, unsigned long, XSetWindowAttributes*);
	if (!real)
		real = dlsym(RTLD_NEXT, "XChangeWindowAttributes");
	if ((mask & CWOverrideRedirect) && attributes)
		set_unmanaged(window, attributes->override_redirect);
	return real(display, window, mask, attributes);
}

int XChangeProperty(Display* display, Window window, Atom property, Atom type, int format,
                    int mode, const unsigned char* data, int nelements)
{
	static int (*real)(Display*, Window, Atom, Atom, int, int, const unsigned char*, int);
	static Atom window_type, dialog, dropdown_menu;
	if (!real)
		real = dlsym(RTLD_NEXT, "XChangeProperty");
	if (format == 32 && nelements == 1 && data && is_unmanaged(window))
	{
		if (!window_type)
		{
			dialog = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DIALOG", False);
			dropdown_menu = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", False);
			window_type = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
		}
		if (property == window_type && *(const Atom*)data == dialog)
			data = (const unsigned char*)&dropdown_menu;
	}
	return real(display, window, property, type, format, mode, data, nelements);
}

/* Per key code: its press was withheld, so its release will be too; and its
 * press went through, so the client holds it down. */
static unsigned char withheld[256], down[256];

static int keeps_super(void)
{
	static int keeps = -1;
	if (keeps < 0)
	{
		const char* wanted = getenv("WINAPP_SUPER");
		keeps = (wanted && strcmp(wanted, "windows") == 0) ? 0 : 1;
	}
	return keeps;
}

/* True when a key event belongs to the desktop and must not reach Windows. */
static int belongs_to_desktop(XKeyEvent* key)
{
	const unsigned code = key->keycode & 0xff;
	const KeySym symbol = XLookupKeysym(key, 0);
	if (symbol == XK_Super_L || symbol == XK_Super_R)
		return 1;
	if (key->type == KeyRelease)
	{
		const int was = withheld[code];
		withheld[code] = down[code] = 0;
		return was;
	}
	/* The state says what was held before this press: Mod4 is Super. A key
	 * that was already down when Super joined it is repeating, and stays
	 * with Windows so that its release still matches a press there. */
	if ((key->state & Mod4Mask) && !down[code])
	{
		withheld[code] = 1;
		return 1;
	}
	withheld[code] = 0;
	down[code] = 1;
	return 0;
}

/* The client reads the held modifiers here when a window of its gains the
 * focus, and later releases in Windows whatever it found held. */
Bool XQueryPointer(Display* display, Window window, Window* root, Window* child, int* root_x,
                   int* root_y, int* x, int* y, unsigned int* mask)
{
	static Bool (*real)(Display*, Window, Window*, Window*, int*, int*, int*, int*,
	                    unsigned int*);
	if (!real)
		real = dlsym(RTLD_NEXT, "XQueryPointer");
	const Bool rc = real(display, window, root, child, root_x, root_y, x, y, mask);
	if (mask && keeps_super())
		*mask &= ~(unsigned int)Mod4Mask;
	return rc;
}

int XNextEvent(Display* display, XEvent* event)
{
	static int (*real)(Display*, XEvent*);
	if (!real)
		real = dlsym(RTLD_NEXT, "XNextEvent");
	int rc = real(display, event);
	/* An event is never dropped, which would mean waiting here for the next
	 * one: it is turned into a kind the client has no handler for. */
	if (event->type == ConfigureNotify &&
	    (event->xconfigure.override_redirect || is_unmanaged(event->xconfigure.window)))
	{
		event->type = GravityNotify;
	}
	else if ((event->type == KeyPress || event->type == KeyRelease) && keeps_super() &&
	         belongs_to_desktop(&event->xkey))
	{
		event->type = GravityNotify;
	}
	else if (event->type == FocusOut)
	{
		/* the client lets go of every key now, and releases go elsewhere */
		memset(withheld, 0, sizeof(withheld));
		memset(down, 0, sizeof(down));
	}
	return rc;
}

int XDestroyWindow(Display* display, Window window)
{
	static int (*real)(Display*, Window);
	if (!real)
		real = dlsym(RTLD_NEXT, "XDestroyWindow");
	set_unmanaged(window, 0);
	return real(display, window);
}
