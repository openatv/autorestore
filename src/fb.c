#include <linux/fb.h>
#include <linux/kd.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <memory.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdarg.h>
#include "font.h"

#ifndef FB_DEV
# define FB_DEV "/dev/fb0"
#endif


int init_framebuffer(int steps);
void close_framebuffer();
int show_main_window();
void set_step_progress(int percent);
void set_step_text(char* str);

#define TRANS "\x00\x00\x00\x00"
//#define BLACK "\x00\x00\x00\x30"
//#define WHITE "\xFF\xFF\xFF\xFF"
//#define RED   "\x00\x00\xFF\xFF"
//#define GREEN "\x00\xFF\x00\xFF"
//#define BLUE  "\xFF\x00\x00\xFF"

#define FB_WIDTH 1280
#define FB_HEIGHT 720
#define FB_BPP 32

#ifndef FBIO_BLIT
#define FBIO_SET_MANUAL_BLIT _IOW('F', 0x21, __u8)
#define FBIO_BLIT 0x22
#endif

struct config {
    char title[128];
    int width;
    int height;
    unsigned char bg_color[4];
    unsigned char bar_color[4];
    unsigned char text_color[4];
};

int g_fbFd = -1;
unsigned char *g_lfb = NULL;
int g_manual_blit = 0;
struct fb_var_screeninfo g_screeninfo_var;
struct fb_fix_screeninfo g_screeninfo_fix;
int g_step = 1;

// box
struct window_t
{
	int x1;		// left upper corner
	int y1;		// left upper corner
	int x2;		// right lower corner
	int y2;		// right lower corner
	int width;
	int height;
} g_window;

// progressbar
struct progressbar
{
	int x1;		// left upper corner (outer dimension)
	int y1;		// left upper corner (outer dimension)
	int x2;		// right lower corner (outer dimension)
	int y2;		// right lower corner (outer dimension)
	int outer_border_width;
	int inner_border_width;
	int width; // inner dimension
	int height; // inner dimension
	int steps;
};

struct progressbar g_pb_overall;
struct config cfg;

void parse_hex_color_bgra(const char *hex, unsigned char *bgra) {
    if (!hex || hex[0] != '#' || strlen(hex) != 9) {
        bgra[0] = 0xFF; // B
        bgra[1] = 0xFF; // G
        bgra[2] = 0xFF; // R
        bgra[3] = 0xFF; // A
        return;
    }

    unsigned int r, g, b, a;
    sscanf(hex, "#%02x%02x%02x%02x", &r, &g, &b, &a);

    // BGRA
    bgra[0] = b;
    bgra[1] = g;
    bgra[2] = r;
    bgra[3] = a;
}

void load_config(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
		memset(&cfg, 0, sizeof(cfg));
		strcpy(cfg.title, "Fast Restore in Progress");
		cfg.width = 800;
		cfg.height = 200;
		parse_hex_color_bgra("#00000000", cfg.bg_color);
		parse_hex_color_bgra("#CCCCCCFF", cfg.bar_color);
		parse_hex_color_bgra("#FFFFFFFF", cfg.text_color);	
		return;
    }

    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n')
            continue;

        char key[64], value[128];
        if (sscanf(line, "%63[^=]=%127[^\n]", key, value) == 2) {
            if (strcmp(key, "title") == 0)
                strncpy(cfg.title, value, sizeof(cfg.title));
            else if (strcmp(key, "width") == 0)
                cfg.width = atoi(value);
            else if (strcmp(key, "height") == 0)
                cfg.height = atoi(value);
            else if (strcmp(key, "bg_color") == 0)
				parse_hex_color_bgra(value, cfg.bg_color);
			else if (strcmp(key, "bar_color") == 0)
				parse_hex_color_bgra(value, cfg.bar_color);
			else if (strcmp(key, "text_color") == 0)
				parse_hex_color_bgra(value, cfg.text_color);
        }
    }
    fclose(f);
}


void blit()
{
	if (g_manual_blit == 1) {
		if (ioctl(g_fbFd, FBIO_BLIT) < 0)
			perror("FBIO_BLIT");
	}
}

void enableManualBlit()
{
	unsigned char tmp = 1;
	if (ioctl(g_fbFd, FBIO_SET_MANUAL_BLIT, &tmp)<0)
		perror("FBIO_SET_MANUAL_BLIT");
	else
		g_manual_blit = 1;
}

void disableManualBlit()
{
	unsigned char tmp = 0;
	if (ioctl(g_fbFd, FBIO_SET_MANUAL_BLIT, &tmp)<0)
		perror("FBIO_SET_MANUAL_BLIT");
	else
		g_manual_blit = 0;
}

void set_window_dimension(int width, int height)
{
	g_window.width = width;
	g_window.height = height;
	g_window.x1 = g_screeninfo_var.xres - g_window.width;
	g_window.y1 = 0;
	g_window.x2 = g_screeninfo_var.xres;
	g_window.y2 = g_window.height;
}

void paint_box(int x1, int y1, int x2, int y2, char* color)
{
	int x,y;
	for (y = y1; y < y2; y++)
		for (x = x1; x < x2; x++)
			memcpy(&g_lfb[(x + g_screeninfo_var.xoffset) * 4 + (y + g_screeninfo_var.yoffset) * g_screeninfo_fix.line_length], color, 4);
}

void init_progressbar(int steps)
{
	g_pb_overall.width = g_window.width - 30;
	g_pb_overall.height = 20;
	g_pb_overall.outer_border_width = 2;
	g_pb_overall.inner_border_width = 1;

	int borders = + 2 * g_pb_overall.outer_border_width + 2 * g_pb_overall.inner_border_width;

	g_pb_overall.x1 = g_window.x1 + 10;
	g_pb_overall.y1 = g_window.y1 + 50;
	g_pb_overall.x2 = g_pb_overall.x1 + g_pb_overall.width + borders;
	g_pb_overall.y2 = g_pb_overall.y1 + g_pb_overall.height + borders;
}

void paint_progressbar()
{
	paint_box(g_pb_overall.x1, g_pb_overall.y1, g_pb_overall.x2, g_pb_overall.y2, cfg.bar_color);
	paint_box(g_pb_overall.x1 + g_pb_overall.outer_border_width
			, g_pb_overall.y1 + g_pb_overall.outer_border_width
			, g_pb_overall.x2 - g_pb_overall.outer_border_width
			, g_pb_overall.y2 - g_pb_overall.outer_border_width
			, cfg.bg_color);
}

void close_framebuffer()
{
	// hide all old osd content
	paint_box(0, 0, g_screeninfo_var.xres, g_screeninfo_var.yres, TRANS);

	if (g_lfb)
	{
		msync(g_lfb, g_screeninfo_fix.smem_len, MS_SYNC);
		munmap(g_lfb, g_screeninfo_fix.smem_len);
	}

	if (g_fbFd >= 0)
	{
		disableManualBlit();
		close(g_fbFd);
		g_fbFd = -1;
	}
}

int get_screeninfo()
{
	if (ioctl(g_fbFd, FBIOGET_VSCREENINFO, &g_screeninfo_var) < 0)
	{
		perror("FBIOGET_VSCREENINFO");
		return 0;
	}

	if (ioctl(g_fbFd, FBIOGET_FSCREENINFO, &g_screeninfo_fix) < 0)
	{
		perror("FBIOGET_FSCREENINFO");
		return 0;
	}

	return 1;
}

// Needed by hisilicon boxes to show gui while e2 is running. screeninfo_var.yoffset is not 0 on these boxes
int set_screeninfo()
{
	g_screeninfo_var.yres_virtual = g_screeninfo_var.yres * 2;
	g_screeninfo_var.xoffset = g_screeninfo_var.yoffset = 0;

	if (ioctl(g_fbFd, FBIOPUT_VSCREENINFO, &g_screeninfo_var) < 0)
	{
		perror("Cannot set variable information");
		return 0;
	}

	return 1;
}

int open_framebuffer()
{
	g_fbFd = open(FB_DEV, O_RDWR);
	if (g_fbFd < 0)
	{
		perror(FB_DEV);
		goto nolfb;
	}

	enableManualBlit();

	return 1;

nolfb:
	if (g_fbFd >= 0)
	{
		close(g_fbFd);
		g_fbFd = -1;
	}
	printf("framebuffer not available.\n");
	return 0;
}

int mmap_fb()
{
	g_lfb = (unsigned char*)mmap(0, g_screeninfo_fix.smem_len, PROT_WRITE|PROT_READ, MAP_SHARED, g_fbFd, 0);
	if (!g_lfb)
	{
		perror("mmap");
		return 0;
	}
	return 1;
}

int set_fb_resolution()
{
	g_screeninfo_var.xres_virtual = g_screeninfo_var.xres = FB_WIDTH;
	g_screeninfo_var.yres_virtual = g_screeninfo_var.yres = FB_HEIGHT;
	g_screeninfo_var.bits_per_pixel = FB_BPP;
	g_screeninfo_var.xoffset = g_screeninfo_var.yoffset = 0;
	g_screeninfo_var.height = 0;
	g_screeninfo_var.width = 0;

	if (ioctl(g_fbFd, FBIOPUT_VSCREENINFO, &g_screeninfo_var) < 0)
	{
		printf("Error: Cannot set variable information");
		return 0;
	}

	if (!get_screeninfo())
	{
		return 0;
	}

	if (g_screeninfo_var.xres != FB_WIDTH || g_screeninfo_var.yres != FB_HEIGHT)
	{
		printf("Warning: Cannot change resolution: using %dx%dx%d", g_screeninfo_var.xres, g_screeninfo_var.yres, g_screeninfo_var.bits_per_pixel);
	}

	if (g_screeninfo_var.bits_per_pixel != FB_BPP)
	{
		printf("Error: Only 32 bit per pixel supported. Framebuffer currently use %d\n", g_screeninfo_var.bits_per_pixel);
		return 0;
	}

	return 1;
}

void set_step_progress(int percent)
{
	if (g_fbFd == -1)
		return;

	if (percent < 0)
		percent = 0;
	if (percent > 100)
		percent = 100;
	int x = g_pb_overall.x1 + g_pb_overall.outer_border_width + g_pb_overall.inner_border_width;
	int y = g_pb_overall.y1 + g_pb_overall.outer_border_width + g_pb_overall.inner_border_width;

	paint_box(x
			, y
			, (int)(x + g_pb_overall.width / 100.0 * percent)
			, y + g_pb_overall.height
			, cfg.bar_color);
	blit();
}

void render_char(char ch, int x, int y, char* color, int thick)
{
	const unsigned short* bitmap = font[ch-0x20];

	int h, w, line;
	const unsigned int pos = (y + g_screeninfo_var.yoffset) * g_screeninfo_fix.line_length + (x + g_screeninfo_var.xoffset) * 4;
	for (h = 0; h < CHAR_HEIGHT; h++)
	{
		line = bitmap[h] >> 2;  // ignore 2 lsb bits
		for (w = CHAR_WIDTH - 1; w >= 0; w--)
		{
			if ((line & 0x01) == 0x01)
			{
				memcpy(&g_lfb[pos + (thick + 1) * h * g_screeninfo_fix.line_length + (thick + 1) * w * 4], color, 4);
				if (thick)
				{
					memcpy(&g_lfb[pos + 2 * h * g_screeninfo_fix.line_length + 2 * w * 4 + 4], color, 4);
					memcpy(&g_lfb[pos + (2 * h + 1) * g_screeninfo_fix.line_length + 2 * w * 4], color, 4);
					memcpy(&g_lfb[pos + (2 * h + 1) * g_screeninfo_fix.line_length + 2 * w * 4 + 4], color, 4);
				}
			}

			line = line >> 1;
		}
	}
}

void render_string(char* str, int x, int y, char* color, int thick)
{
	int i;
	for (i = 0; i < strlen(str); i++)
		render_char(str[i], x + i * (CHAR_WIDTH + CHAR_WIDTH * thick), y, color, thick);
}

void remove_substring(char* str, const char* to_remove) {
    char* pos = strstr(str, to_remove);
    if (pos != NULL) {
        int len_to_remove = strlen(to_remove);
        int len_rest = strlen(pos + len_to_remove);
        memmove(pos, pos + len_to_remove, len_rest + 1);
    }
}

void render_string_wrap(char* str, int x, int y, char* color, int thick, int max_width)
{
	int cur_x = x;
	int cur_y = y;
	int char_width = CHAR_WIDTH + CHAR_WIDTH * thick;
	int line_height = CHAR_HEIGHT + CHAR_HEIGHT * thick;
	int len = strlen(str);
	int i = 0;

	while (i < len)
	{
		if (str[i] == '\n')
		{
			cur_x = x;
			cur_y += line_height;
			i++;
			continue;
		}

		int word_start = i;

		while (i < len && !isspace((unsigned char)str[i]) && str[i] != '\n')
			i++;

		int word_end = i;
		int word_length = word_end - word_start;

		int word_pixel_width = word_length * char_width;

		if (cur_x + word_pixel_width > x + max_width)
		{
			cur_x = x;
			cur_y += line_height;
		}

		for (int j = word_start; j < word_end; j++)
		{
			render_char(str[j], cur_x, cur_y, color, thick);
			cur_x += char_width;
		}

		while (i < len && isspace((unsigned char)str[i]) && str[i] != '\n')
		{
			if (cur_x + char_width > x + max_width)
			{
				cur_x = x;
				cur_y += line_height;
			}

			if (str[i] == ' ')
				render_char(' ', cur_x, cur_y, color, thick);

			cur_x += char_width;
			i++;
		}
	}
}

void set_title(char* str)
{
	if (g_fbFd == -1)
		return;

	// hide text
	paint_box(g_window.x1 + 10
			, g_window.y1 + 10
			, g_window.x2
			, g_window.y1 + 10 + CHAR_HEIGHT
			, cfg.bg_color);

	// display text
	render_string(str
				, g_window.x1 + 10
				, g_window.y1 + 10
				, cfg.text_color
				, 0);

	blit();
}

void set_step_text(char* str) // DONE
{
	if (g_fbFd == -1)
		return;

	remove_substring(str, "enigma2-plugin-extensions-");
	remove_substring(str, "enigma2-plugin-systemplugins-");
	remove_substring(str,"https://raw.githubusercontent.com/oe-alliance/");
	remove_substring(str,"https://feeds2.mynonpublic.com/");
	remove_substring(str,"/Packages.gz");

	// hide text
	paint_box(g_window.x1 + 10
			, g_window.y1 + 90
			, g_window.x2
			, g_window.y1 + 90 + CHAR_HEIGHT * 3 // 3 lines
			, cfg.bg_color);

	// display text
	render_string_wrap(str
				, g_window.x1 + 10
				, g_window.y1 + 90
				, cfg.text_color
				, 0
				, g_window.width - 20);

	blit();
}

int init_framebuffer(int steps)
{
	if (g_fbFd == -1)
		if (!open_framebuffer())
		{
			return 0;
		}

	if (!get_screeninfo())
	{
		printf("Error: Cannot get screen info\n");
		close_framebuffer();
		return 0;
	}

	if (!set_screeninfo())
	{
		printf("Error: Cannot set screen info\n");
		close_framebuffer();
		return 0;
	}

	if (!mmap_fb())
	{
		close_framebuffer();
		return 0;
	}

	set_window_dimension(cfg.width, cfg.height);

	// hide all old osd content
	paint_box(0, 0, g_screeninfo_var.xres, g_screeninfo_var.yres, TRANS);

	init_progressbar(steps);

	return 1;
}

int show_main_window()
{
	// hide all old osd content
	paint_box(0, 0, g_screeninfo_var.xres, g_screeninfo_var.yres, TRANS);

	// paint window
	paint_box(g_window.x1, g_window.y1, g_window.x2, g_window.y2, cfg.bg_color);
	paint_progressbar();

	set_title(cfg.title);

	return 1;
}
