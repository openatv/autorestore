/*
 * fbprogress: the progress of FastRestore as a card at the bottom of the screen, over the boot logo.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 */

#include <linux/fb.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "lvgl.h"
#include "main.h"

#ifndef FBIO_BLIT
#define FBIO_SET_MANUAL_BLIT _IOW('F', 0x21, __u8)
#define FBIO_BLIT 0x22
#endif

LV_FONT_DECLARE(fbp_font_16)
LV_FONT_DECLARE(fbp_font_24)
LV_FONT_DECLARE(fbp_font_30)

#define COLOR_GROUND 0x0b1016
#define COLOR_TRACK 0x1b2533
#define COLOR_TEXT 0xe8edf2
#define COLOR_MUTED 0x7d8fa1
#define COLOR_FOCUS 0x2b7fd9
#define COLOR_FOCUS_LIGHT 0x5b9de6
#define COLOR_WARN 0xf2b84b
#define COLOR_RED 0xef5b5b
#define BAR_OPA 217  /* The boot logo shines through a little. */
#define SUB_OPA 140  /* The step within a phase, a light line in the bar. */

#define DESIGN_HEIGHT 720  /* Sizes are for a screen of 720 lines. */
#define DRAW_ROWS 40
#define REDRAW_MS 100  /* Text alone redraws at most this often. */
#define FAIL_MS 1500  /* A failed package stays red this long, the next texts wait. */

static int fb_fd = -1;
static unsigned char *fb_mem;
static size_t fb_len;
static struct fb_var_screeninfo var;
static struct fb_var_screeninfo before;  /* The mode and the page shown before. */
static struct fb_fix_screeninfo fix;
static int manual_blit;

static int bar_x, bar_y, bar_w, bar_h;
static uint32_t *backing;  /* The pixels below the bar, given back at the end. */

static lv_display_t *display;
static uint8_t *draw_buffer;
static lv_obj_t *step_label;
static lv_obj_t *percent_label;
static lv_obj_t *time_label;
static lv_obj_t *fill;
static lv_obj_t *sub_fill;
static lv_obj_t *frame;

static time_t started;
static int percent;
static int sub_percent = -1;  /* Without a step within the phase. */
static long shown_seconds = -1;
static int dirty;
static char step_text[200];
static char fail_text[200];
static uint32_t failed_until;  /* While it lasts, fail_text is shown red. */
static int fail_shown;
static uint32_t drawn_at;

static uint32_t milliseconds(void)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint32_t)(now.tv_sec * 1000 + now.tv_nsec / 1000000);
}

static int px(int value)
{
	return value * (int)var.yres / DESIGN_HEIGHT;
}

static const lv_font_t *font(void)
{
	return var.yres >= 1400 ? &fbp_font_30 : var.yres >= 1000 ? &fbp_font_24 : &fbp_font_16;
}

/* Framebuffer */

static uint32_t *pixel(int x, int y)
{
	size_t offset = (size_t)(y + (int)var.yoffset) * fix.line_length + (size_t)(x + (int)var.xoffset) * 4;
	return offset + 4 <= fb_len ? (uint32_t *)(fb_mem + offset) : NULL;
}

static void blit(void)
{
	if (manual_blit && ioctl(fb_fd, FBIO_BLIT) < 0)
		perror("FBIO_BLIT");
}

static void set_manual_blit(unsigned char on)
{
	if (ioctl(fb_fd, FBIO_SET_MANUAL_BLIT, &on) < 0)
		perror("FBIO_SET_MANUAL_BLIT");
	else
		manual_blit = on;
}

/* Triple, double or single buffering, showing the first page; some boxes need it. When the driver refuses all,
 * the current mode stays. */
static int set_screeninfo(void)
{
	static const unsigned int factors[] = {3, 2, 1};
	struct fb_var_screeninfo original = var;
	if (!original.yres)
		return 1;
	for (int i = 0; i < 3; ++i) {
		var = original;
		var.yres_virtual = original.yres * factors[i];
		var.xoffset = 0;
		var.yoffset = 0;
		var.activate = FB_ACTIVATE_ALL;
		if (ioctl(fb_fd, FBIOPUT_VSCREENINFO, &var) == 0)
			break;
	}
	return ioctl(fb_fd, FBIOGET_VSCREENINFO, &var) == 0 && ioctl(fb_fd, FBIOGET_FSCREENINFO, &fix) == 0;
}

static int map_framebuffer(void)
{
	size_t length = fix.smem_len;  /* Some drivers report 0. */
	if (!length)
		length = (size_t)fix.line_length * var.yres_virtual;
	if (!length)
		return 0;
	fb_mem = mmap(NULL, length, PROT_WRITE | PROT_READ, MAP_SHARED, fb_fd, 0);
	if (fb_mem == MAP_FAILED) {
		fb_mem = NULL;
		perror("mmap");
		return 0;
	}
	fb_len = length;
	return 1;
}

/* LVGL */

/* The bar over the pixels below it. */
static void flush(lv_display_t *disp, const lv_area_t *area, uint8_t *pixels)
{
	const uint32_t *source = (const uint32_t *)pixels;
	for (int32_t y = area->y1; y <= area->y2; ++y)
		for (int32_t x = area->x1; x <= area->x2; ++x, ++source) {
			uint32_t *target = pixel(bar_x + x, bar_y + y);
			uint32_t below = backing[y * bar_w + x];
			uint32_t alpha = *source >> 24;
			uint32_t mixed = 0;
			if (!target)
				continue;
			if (alpha == 255 || !below)
				mixed = alpha ? *source : below;
			else if (!alpha)
				mixed = below;
			else {
				uint32_t below_alpha = below >> 24;
				for (int shift = 0; shift < 24; shift += 8)
					mixed |= ((((*source >> shift) & 0xff) * alpha + ((below >> shift) & 0xff) * (255 - alpha)) / 255)
						<< shift;
				mixed |= (alpha + below_alpha * (255 - alpha) / 255) << 24;
			}
			*target = mixed;
		}
	if (lv_display_flush_is_last(disp))
		blit();
	lv_display_flush_ready(disp);
}

static lv_obj_t *label(lv_obj_t *parent, uint32_t color)
{
	lv_obj_t *obj = lv_label_create(parent);
	lv_label_set_text(obj, "");
	lv_obj_set_style_text_font(obj, font(), 0);
	lv_obj_set_style_text_color(obj, lv_color_hex(color), 0);
	return obj;
}

/* One line of text and the bar below it: the step on the left, the warning, percent and time on the right. */
static void build(void)
{
	lv_obj_t *screen = lv_display_get_screen_active(display);
	lv_obj_t *row;
	lv_obj_t *track;
	lv_obj_t *dot;

	lv_obj_set_scrollable(screen, false);
	lv_obj_set_style_bg_opa(screen, BAR_OPA, 0);
	lv_obj_set_style_bg_color(screen, lv_color_hex(COLOR_GROUND), 0);
	lv_obj_set_style_radius(screen, px(10), 0);
	lv_obj_set_style_pad_ver(screen, px(10), 0);
	lv_obj_set_style_pad_hor(screen, (int32_t)var.xres * 15 / 1000, 0);
	lv_obj_set_style_pad_row(screen, px(8), 0);
	lv_obj_set_flex_flow(screen, LV_FLEX_FLOW_COLUMN);

	row = lv_obj_create(screen);
	lv_obj_remove_style_all(row);
	lv_obj_set_scrollable(row, false);
	lv_obj_set_size(row, LV_PCT(100), LV_SIZE_CONTENT);
	lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
	lv_obj_set_style_pad_column(row, px(8), 0);
	lv_label_set_text(label(row, COLOR_FOCUS_LIGHT), "Settings Restore");  /* What runs, before the step. */
	dot = label(row, COLOR_MUTED);
	lv_label_set_text(dot, "\xC2\xB7");
	step_label = label(row, COLOR_TEXT);
	lv_obj_set_flex_grow(step_label, 1);
	lv_label_set_long_mode(step_label, LV_LABEL_LONG_MODE_DOTS);
	lv_label_set_text(label(row, COLOR_WARN), "\xE2\x9A\xA0 Do not switch off");
	dot = label(row, COLOR_MUTED);
	lv_label_set_text(dot, "\xC2\xB7");
	percent_label = label(row, COLOR_TEXT);
	dot = label(row, COLOR_MUTED);
	lv_label_set_text(dot, "\xC2\xB7");
	time_label = label(row, COLOR_MUTED);

	track = lv_obj_create(screen);
	lv_obj_remove_style_all(track);
	lv_obj_set_scrollable(track, false);
	lv_obj_set_size(track, LV_PCT(100), px(6) > 3 ? px(6) : 3);
	lv_obj_set_style_bg_opa(track, LV_OPA_COVER, 0);
	lv_obj_set_style_bg_color(track, lv_color_hex(COLOR_TRACK), 0);
	lv_obj_set_style_radius(track, LV_RADIUS_CIRCLE, 0);
	lv_obj_set_style_clip_corner(track, true, 0);
	fill = lv_obj_create(track);
	lv_obj_remove_style_all(fill);
	lv_obj_set_size(fill, 0, LV_PCT(100));
	lv_obj_set_style_bg_opa(fill, LV_OPA_COVER, 0);
	lv_obj_set_style_bg_color(fill, lv_color_hex(COLOR_FOCUS), 0);
	lv_obj_set_style_radius(fill, LV_RADIUS_CIRCLE, 0);
	sub_fill = lv_obj_create(track);
	lv_obj_remove_style_all(sub_fill);
	lv_obj_set_size(sub_fill, 0, px(2) > 2 ? px(2) : 2);
	lv_obj_set_align(sub_fill, LV_ALIGN_BOTTOM_LEFT);
	lv_obj_set_style_bg_opa(sub_fill, SUB_OPA, 0);
	lv_obj_set_style_bg_color(sub_fill, lv_color_hex(COLOR_TEXT), 0);
	lv_obj_set_hidden(sub_fill, true);

	frame = lv_obj_create(lv_display_get_layer_top(display));  /* The blue frame like ofgwrite --dim, over all. */
	lv_obj_remove_style_all(frame);
	lv_obj_set_size(frame, bar_w, bar_h);
	lv_obj_set_style_radius(frame, px(10), 0);
	lv_obj_set_style_border_width(frame, px(2) > 2 ? px(2) : 2, 0);
	lv_obj_set_style_border_color(frame, lv_color_hex(COLOR_FOCUS), 0);
}

static void draw(int force)
{
	char text[16];
	long seconds = (long)(time(NULL) - started);
	uint32_t now = milliseconds();
	if (fail_shown && (int32_t)(failed_until - now) <= 0)
		dirty = 1;  /* Back to the latest text. */
	if (!display || (!force && !dirty && seconds == shown_seconds) || (!force && now - drawn_at < REDRAW_MS))
		return;
	snprintf(text, sizeof(text), "%d %%", percent);
	lv_label_set_text(percent_label, text);
	snprintf(text, sizeof(text), "%ld:%02ld", seconds / 60, seconds % 60);
	lv_label_set_text(time_label, text);
	lv_obj_set_width(fill, LV_PCT(percent));
	lv_obj_set_hidden(sub_fill, sub_percent < 0);
	lv_obj_set_width(sub_fill, LV_PCT(sub_percent < 0 ? 0 : sub_percent));
	fail_shown = (int32_t)(failed_until - now) > 0;
	lv_label_set_text(step_label, fail_shown ? fail_text : step_text);
	lv_obj_set_style_text_color(step_label, lv_color_hex(fail_shown ? COLOR_RED : COLOR_TEXT), 0);
	lv_obj_set_style_bg_color(sub_fill, lv_color_hex(fail_shown ? COLOR_RED : COLOR_TEXT), 0);
	lv_obj_invalidate(lv_display_get_screen_active(display));  /* Shorter texts would leave their old ends. */
	lv_refr_now(display);
	shown_seconds = seconds;
	dirty = 0;
	drawn_at = now;
}

int init_framebuffer(void)
{
	int text_height;
	started = time(NULL);
	fb_fd = open("/dev/fb0", O_RDWR);
	if (fb_fd < 0) {
		perror("/dev/fb0");
		return 0;
	}
	set_manual_blit(1);
	if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &var) < 0 || ioctl(fb_fd, FBIOGET_FSCREENINFO, &fix) < 0) {
		close_framebuffer();
		return 0;
	}
	before = var;
	if (!set_screeninfo() || var.bits_per_pixel != 32 || !map_framebuffer()) {
		printf("framebuffer not usable (%u bpp)\n", var.bits_per_pixel);
		close_framebuffer();
		return 0;
	}
	text_height = lv_font_get_line_height(font());
	bar_x = (int)var.xres * 25 / 1000;  /* A card a little inside the screen, its text where the bar had it. */
	bar_w = (int)var.xres - 2 * bar_x;
	bar_h = 2 * px(10) + text_height + px(8) + (px(6) > 3 ? px(6) : 3);
	bar_y = (int)var.yres - bar_h - (int)var.yres * 6 / 100;
	backing = calloc((size_t)bar_w * bar_h, 4);
	if (!backing) {
		close_framebuffer();
		return 0;
	}
	for (int y = 0; y < bar_h; ++y)
		for (int x = 0; x < bar_w; ++x) {
			uint32_t *p = pixel(bar_x + x, bar_y + y);
			backing[y * bar_w + x] = p ? *p : 0;
		}
	lv_init();
	lv_tick_set_cb(milliseconds);
	draw_buffer = malloc((size_t)bar_w * DRAW_ROWS * 4);
	display = lv_display_create(bar_w, bar_h);
	if (!draw_buffer || !display) {
		close_framebuffer();
		return 0;
	}
	lv_display_set_color_format(display, LV_COLOR_FORMAT_ARGB8888);
	lv_display_set_buffers(display, draw_buffer, NULL, (uint32_t)bar_w * DRAW_ROWS * 4, LV_DISPLAY_RENDER_MODE_PARTIAL);
	lv_display_set_flush_cb(display, flush);
	build();
	draw(1);
	return 1;
}

void set_progress(int value, const char *text, int failed)
{
	percent = value < 0 ? 0 : value > 100 ? 100 : value;
	if (failed) {
		snprintf(fail_text, sizeof(fail_text), "%s", text);
		failed_until = milliseconds() + FAIL_MS;
	} else
		snprintf(step_text, sizeof(step_text), "%s", text);
	dirty = 1;
	draw(failed);
}

/* The step within the phase, e.g. the package of all to install; below 0 hides it. */
void set_sub_progress(int value)
{
	sub_percent = value < 0 ? -1 : value > 100 ? 100 : value;
	dirty = 1;
	draw(0);
}

/* Shows what waited for REDRAW_MS and the running time. */
void tick_framebuffer(void)
{
	draw(0);
}

void close_framebuffer(void)
{
	if (fb_mem) {
		struct fb_var_screeninfo back = before;  /* Gives the screen back as it was: pixels, mode and page. */
		for (int y = 0; backing && y < bar_h; ++y)
			for (int x = 0; x < bar_w; ++x) {
				uint32_t *p = pixel(bar_x + x, bar_y + y);
				if (p)
					*p = backing[y * bar_w + x];
			}
		blit();
		back.activate = FB_ACTIVATE_ALL;
		if (back.yres && ioctl(fb_fd, FBIOPUT_VSCREENINFO, &back) < 0)
			perror("FBIOPUT_VSCREENINFO");
		msync(fb_mem, fb_len, MS_SYNC);
		munmap(fb_mem, fb_len);
		fb_mem = NULL;
		fb_len = 0;
	}
	if (fb_fd >= 0) {
		set_manual_blit(0);
		close(fb_fd);
		fb_fd = -1;
	}
	free(backing);
	backing = NULL;
}
