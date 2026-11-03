/*
 * winapp-xshim: corrections to how FreeRDP's X11 client (xfreerdp) behaves on
 * a tiling Wayland desktop. winapp loads it into the client with LD_PRELOAD;
 * nothing else is affected. There are three: what the client does with the
 * Super key, how large it shows the mouse pointer, and a clipboard loop
 * (refused_targets, below).
 *
 * (Before 3.0, winapp showed each Windows app in a window of its own, and
 * this also corrected what xfreerdp did to Windows' hidden helper windows.
 * The whole desktop in one window has no such windows.)
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
 *
 * Some Super shortcuts are the desktop's way of pressing another chord in
 * the focused window: Omarchy's Super+C, V, X and A send Ctrl+C, V, X and A.
 * The compositor does that by saying Ctrl is held and pressing the C; no
 * Ctrl key ever goes down. xfreerdp passes Windows the keys pressed, not
 * the modifiers held, so Windows would see a bare C. A key whose state
 * names a modifier with no key of it down is therefore such a chord: it goes
 * through even with Super held, and the shim presses the missing modifiers
 * in front of it and lets go of them after its release. A Super shortcut
 * pressed by hand has its modifiers' keys down and is withheld as before.
 *
 * --- The mouse pointer ---
 *
 * On a scaled monitor Windows is asked to draw at that scale itself (the
 * compositor leaves X11 windows unscaled), so at 200% it sends a pointer of
 * twice the size, and the client hands the picture to X as it comes. But a
 * compositor shows an X11 client's pointer at the monitor's scale whatever
 * it does with its windows, which is why an ordinary X11 program's 24 pixel
 * pointer looks right. The Windows pointer is scaled twice and comes out
 * double the size. WINAPP_POINTER in the environment is the monitor's scale
 * in percent; pointer pictures are reduced by it before X gets them.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>

/* Per key code: its press was withheld, so its release will be too; and its
 * press went through, so the client holds it down. */
static unsigned char withheld[256], down[256];

/* The modifiers whose keys are physically down, withheld or not, or were
 * found held when the client last asked; and per key code, the modifiers the
 * shim pressed in front of it and must let go of after its release. */
static unsigned held_keys;
static unsigned char added[256];

/* Events the shim has put back in front of the queue, to pass untouched when
 * they come round again: by type, key code and serial. */
static struct
{
	int type;
	unsigned keycode;
	unsigned long serial;
} replays[8];
static int replay_count;

static void put_back(Display* display, XEvent* event)
{
	if (replay_count < (int)(sizeof(replays) / sizeof(replays[0])))
	{
		replays[replay_count].type = event->type;
		replays[replay_count].keycode = event->xkey.keycode;
		replays[replay_count].serial = event->xkey.serial;
		replay_count++;
	}
	XPutBackEvent(display, event);
}

/* True, once, for an event the shim put back. */
static int replayed(const XEvent* event)
{
	if (event->type != KeyPress && event->type != KeyRelease)
		return 0;
	for (int i = 0; i < replay_count; i++)
	{
		if (replays[i].type == event->type && replays[i].keycode == event->xkey.keycode &&
		    replays[i].serial == event->xkey.serial)
		{
			replays[i] = replays[--replay_count];
			return 1;
		}
	}
	return 0;
}

static const struct
{
	unsigned mask;
	KeySym left, right;
} modifiers[] = {
	{ ControlMask, XK_Control_L, XK_Control_R },
	{ ShiftMask, XK_Shift_L, XK_Shift_R },
	{ Mod1Mask, XK_Alt_L, XK_Alt_R },
};
enum { MODIFIERS = sizeof(modifiers) / sizeof(modifiers[0]) };

static unsigned modifier_of(KeySym symbol)
{
	for (int i = 0; i < MODIFIERS; i++)
		if (symbol == modifiers[i].left || symbol == modifiers[i].right)
			return modifiers[i].mask;
	return 0;
}

/* Keeps held_keys up to date and says which modifiers this press claims to
 * be held without a key of theirs down: those the desktop put there. */
static unsigned missing_modifiers(XKeyEvent* key)
{
	const KeySym symbol = XLookupKeysym(key, 0);
	const unsigned mask = modifier_of(symbol);
	if (mask)
	{
		if (key->type == KeyPress)
			held_keys |= mask;
		else
			held_keys &= ~mask;
		return 0;
	}
	if (key->type != KeyPress || symbol == XK_Super_L || symbol == XK_Super_R)
		return 0;
	unsigned all = 0;
	for (int i = 0; i < MODIFIERS; i++)
		all |= modifiers[i].mask;
	return key->state & all & ~held_keys;
}

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
	 * with Windows so that its release still matches a press there. A chord
	 * the desktop sends (missing_modifiers) goes through as well. */
	if ((key->state & Mod4Mask) && !down[code] && !added[code])
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
	/* the client presses in Windows what it finds held here */
	if (mask && rc)
		for (int i = 0; i < MODIFIERS; i++)
			held_keys = (held_keys & ~modifiers[i].mask) | (*mask & modifiers[i].mask);
	return rc;
}

/* True when the owner of the clipboard has just refused to say what it holds.
 * xfreerdp answers that refusal by telling Windows the clipboard changed and
 * asking the owner again, at once. Xwayland can go on refusing, and the two
 * then loop thousands of times a second, each turn a message to Windows'
 * rdpclip.exe, which grows until Windows runs out of memory. Without the
 * refusal the client just waits for the next real change. */
static int refused_targets(Display* display, const XSelectionEvent* selection)
{
	static Display* known;
	static Atom targets;
	if (selection->property != None)
		return 0;
	if (known != display)
	{
		targets = XInternAtom(display, "TARGETS", False);
		known = display;
	}
	return selection->target == targets;
}

/* One modifier key of the given kind, pressed or released, made from key. */
static XEvent modifier_event(Display* display, const XKeyEvent* key, int type, unsigned mask)
{
	XEvent event;
	event.xkey = *key;
	event.type = event.xkey.type = type;
	for (int i = 0; i < MODIFIERS; i++)
		if (modifiers[i].mask == mask)
			event.xkey.keycode = XKeysymToKeycode(display, modifiers[i].left);
	return event;
}

/* Turns a key the desktop sent with modifiers of its own (missing_modifiers)
 * into those modifiers' presses, the key, and on its release their releases.
 * event becomes the first of them; the rest are put back in front of the
 * queue, so that the client finds them waiting. False when event is not
 * part of such a chord and is left as it is. */
static int desktop_chord(Display* display, XEvent* event)
{
	XKeyEvent* key = &event->xkey;
	const unsigned code = key->keycode & 0xff;
	if (key->type == KeyRelease)
	{
		const unsigned mask = added[code];
		if (!mask)
		{
			missing_modifiers(key);
			return 0;
		}
		added[code] = 0;
		withheld[code] = down[code] = 0;
		/* this release first, then the modifiers' in the reverse of the
		 * order they were pressed; put back, so the last comes out first */
		for (int i = 0; i < MODIFIERS; i++)
		{
			if (!(mask & modifiers[i].mask))
				continue;
			XEvent release = modifier_event(display, key, KeyRelease, modifiers[i].mask);
			put_back(display, &release);
		}
		return 1;
	}
	const unsigned mask = down[code] ? 0 : missing_modifiers(key);
	if (!mask)
		return 0;
	added[code] = (unsigned char)mask;
	withheld[code] = 0;
	down[code] = 1;
	/* the modifiers in order, then the key: put back in reverse */
	XEvent original = *event;
	put_back(display, &original);
	int first = 1;
	XEvent press;
	for (int i = MODIFIERS - 1; i >= 0; i--)
	{
		if (!(mask & modifiers[i].mask))
			continue;
		if (!first)
			put_back(display, &press);
		press = modifier_event(display, key, KeyPress, modifiers[i].mask);
		first = 0;
	}
	*event = press;
	return 1;
}

int XNextEvent(Display* display, XEvent* event)
{
	static int (*real)(Display*, XEvent*);
	if (!real)
		real = dlsym(RTLD_NEXT, "XNextEvent");
	int rc = real(display, event);
	if (replayed(event))
		return rc;
	/* An event is never dropped, which would mean waiting here for the next
	 * one: it is turned into a kind the client has no handler for. */
	if ((event->type == KeyPress || event->type == KeyRelease) && keeps_super() &&
	    desktop_chord(display, event))
	{
		/* handled: event is now the first of the chord's presses */
	}
	else if ((event->type == KeyPress || event->type == KeyRelease) && keeps_super() &&
	         belongs_to_desktop(&event->xkey))
	{
		event->type = GravityNotify;
	}
	else if (event->type == SelectionNotify && refused_targets(display, &event->xselection))
	{
		event->type = GravityNotify;
	}
	else if (event->type == FocusOut)
	{
		/* the client lets go of every key now, and releases go elsewhere */
		memset(withheld, 0, sizeof(withheld));
		memset(down, 0, sizeof(down));
		memset(added, 0, sizeof(added));
		held_keys = 0;
		replay_count = 0;
	}
	return rc;
}

/* libXcursor's XcursorImage, which the client fills in itself. Pixels are
 * 32 bits each, alpha included, row after row. */
struct pointer_image
{
	unsigned version, size, width, height, xhot, yhot, delay;
	unsigned* pixels;
};

static unsigned pointer_percent(void)
{
	static int percent = -1;
	if (percent < 0)
	{
		const char* wanted = getenv("WINAPP_POINTER");
		percent = wanted ? atoi(wanted) : 0;
		if (percent <= 100 || percent > 800)
			percent = 100;
	}
	return (unsigned)percent;
}

Cursor XcursorImageLoadCursor(Display* display, const struct pointer_image* image)
{
	static Cursor (*real)(Display*, const struct pointer_image*);
	if (!real)
		real = dlsym(RTLD_NEXT, "XcursorImageLoadCursor");
	const unsigned percent = pointer_percent();
	if (percent == 100 || !image || !image->pixels || image->width < 2 || image->height < 2)
		return real(display, image);

	struct pointer_image small = *image;
	small.width = (image->width * 100 + percent / 2) / percent;
	small.height = (image->height * 100 + percent / 2) / percent;
	if (small.width < 1)
		small.width = 1;
	if (small.height < 1)
		small.height = 1;
	small.xhot = image->xhot * 100 / percent;
	small.yhot = image->yhot * 100 / percent;
	small.pixels = malloc(sizeof(unsigned) * small.width * small.height);
	if (!small.pixels)
		return real(display, image);

	/* each new pixel is the average of the block of old ones it covers */
	for (unsigned y = 0; y < small.height; y++)
	{
		const unsigned top = y * image->height / small.height;
		unsigned bottom = (y + 1) * image->height / small.height;
		if (bottom <= top)
			bottom = top + 1;
		for (unsigned x = 0; x < small.width; x++)
		{
			const unsigned left = x * image->width / small.width;
			unsigned right = (x + 1) * image->width / small.width;
			if (right <= left)
				right = left + 1;
			unsigned sum[4] = { 0, 0, 0, 0 };
			for (unsigned row = top; row < bottom; row++)
			{
				for (unsigned column = left; column < right; column++)
				{
					const unsigned pixel = image->pixels[row * image->width + column];
					for (int channel = 0; channel < 4; channel++)
						sum[channel] += (pixel >> (8 * channel)) & 0xff;
				}
			}
			const unsigned area = (bottom - top) * (right - left);
			unsigned pixel = 0;
			for (int channel = 0; channel < 4; channel++)
				pixel |= ((sum[channel] + area / 2) / area) << (8 * channel);
			small.pixels[y * small.width + x] = pixel;
		}
	}
	const Cursor cursor = real(display, &small);
	free(small.pixels);
	return cursor;
}
