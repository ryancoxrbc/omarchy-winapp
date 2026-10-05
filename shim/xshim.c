/*
 * winapp-xshim: two corrections to how FreeRDP's X11 client (xfreerdp) treats
 * the windows of a single-app (RemoteApp) session. winapp loads it into the
 * client with LD_PRELOAD; nothing else is affected.
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
 * 2. When the compositor scales X11 clients (anything but 1x; always at a
 *    fractional scale, for odd sizes at 2x), a window's geometry comes back
 *    from it rounded by a pixel. xfreerdp reports that to Windows as the user
 *    having moved or resized the window.
 *
 * A program does not expect either to happen to a window it hides. CorelDRAW's
 * welcome screen, or any program with an Internet Explorer control, answers by
 * spinning its UI thread: the window turns white, "Not Responding", for good.
 *
 * So, for override-redirect windows only: the type becomes DROPDOWN_MENU,
 * which is what xfreerdp itself first picks for them and which compositors do
 * not focus, and geometry notifications are dropped, since Windows alone
 * decides where such a window is. Ordinary windows are left exactly as they are.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <X11/Xlib.h>

#define MAX_WINDOWS 4096

static Window unmanaged[MAX_WINDOWS]; /* override-redirect windows of this client */
static int count;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static int is_unmanaged(Window window)
{
	int found = 0;
	pthread_mutex_lock(&lock);
	for (int i = 0; i < count; i++)
	{
		if (unmanaged[i] == window)
		{
			found = 1;
			break;
		}
	}
	pthread_mutex_unlock(&lock);
	return found;
}

static void set_unmanaged(Window window, int on)
{
	pthread_mutex_lock(&lock);
	int at = -1;
	for (int i = 0; i < count; i++)
	{
		if (unmanaged[i] == window)
		{
			at = i;
			break;
		}
	}
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
		set_unmanaged(window, attributes->override_redirect ? 1 : 0);
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
		{
			Atom corrected = dropdown_menu;
			return real(display, window, property, type, format, mode,
			            (const unsigned char*)&corrected, 1);
		}
	}
	return real(display, window, property, type, format, mode, data, nelements);
}

int XNextEvent(Display* display, XEvent* event)
{
	static int (*real)(Display*, XEvent*);
	if (!real)
		real = dlsym(RTLD_NEXT, "XNextEvent");
	int rc = real(display, event);
	if (event->type == ConfigureNotify &&
	    (event->xconfigure.override_redirect || is_unmanaged(event->xconfigure.window)))
	{
		/* Not dropped, which would mean waiting here for another event: turned
		 * into a kind the client has no handler for. */
		event->type = GravityNotify;
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
