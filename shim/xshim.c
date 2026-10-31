/*
 * winapp-xshim: corrections to how FreeRDP's X11 client (xfreerdp) behaves on
 * a tiling Wayland desktop. winapp loads it into the client with LD_PRELOAD;
 * nothing else is affected. There are two: what the client does with the
 * Super key, and how large it shows the mouse pointer.
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
	if ((event->type == KeyPress || event->type == KeyRelease) && keeps_super() &&
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
