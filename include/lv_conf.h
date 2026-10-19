/**
 * LVGL configuration of fbprogress: only what differs from the defaults of
 * LVGL v9.6.0 (src/lv_conf_internal.h fills in everything else).
 */
#ifndef LV_CONF_H
#define LV_CONF_H

/* The C library does the memory and string work */
#define LV_USE_STDLIB_MALLOC    LV_STDLIB_CLIB
#define LV_USE_STDLIB_STRING    LV_STDLIB_CLIB
#define LV_USE_STDLIB_SPRINTF   LV_STDLIB_CLIB

/* Software rendering into the 32 bit framebuffer only */
#define LV_DRAW_SW_SUPPORT_RGB565                  0
#define LV_DRAW_SW_SUPPORT_RGB565_SWAPPED          0
#define LV_DRAW_SW_SUPPORT_RGB565A8                0
#define LV_DRAW_SW_SUPPORT_RGB888                  0
#define LV_DRAW_SW_SUPPORT_ARGB8888_PREMULTIPLIED  0
#define LV_DRAW_SW_SUPPORT_L8                      0
#define LV_DRAW_SW_SUPPORT_AL88                    0

/* Texts in right to left scripts */
#define LV_USE_BIDI                  1
#define LV_USE_ARABIC_PERSIAN_CHARS  1

/* DejaVu Sans from fonts/ (tools/mkfonts.sh), compressed */
#define LV_FONT_MONTSERRAT_14    0
#define LV_FONT_CUSTOM_DECLARE   LV_FONT_DECLARE(fbp_font_16)
#define LV_FONT_DEFAULT          &fbp_font_16
#define LV_USE_FONT_COMPRESSED   1

/* Only labels and plain objects: no themes, layouts or other widgets */
#define LV_USE_OBSERVER          0
#define LV_USE_THEME_SIMPLE      0
#define LV_USE_THEME_MONO        0
#define LV_USE_GRID              0
#define LV_LABEL_TEXT_SELECTION  0
#define LV_USE_ANIMIMG           0
#define LV_USE_ARC               0
#define LV_USE_ARCLABEL          0
#define LV_USE_BAR               0
#define LV_USE_BUTTON            0
#define LV_USE_BUTTONMATRIX      0
#define LV_USE_CALENDAR          0
#define LV_USE_CHART             0
#define LV_USE_CHECKBOX          0
#define LV_USE_DROPDOWN          0
#define LV_USE_IMAGEBUTTON       0
#define LV_USE_KEYBOARD          0
#define LV_USE_LED               0
#define LV_USE_LINE              0
#define LV_USE_LIST              0
#define LV_USE_MENU              0
#define LV_USE_MSGBOX            0
#define LV_USE_ROLLER            0
#define LV_USE_SCALE             0
#define LV_USE_SLIDER            0
#define LV_USE_SPAN              0
#define LV_USE_SPINBOX           0
#define LV_USE_SPINNER           0
#define LV_USE_SWITCH            0
#define LV_USE_TEXTAREA          0
#define LV_USE_TABLE             0
#define LV_USE_TABVIEW           0
#define LV_USE_TILEVIEW          0
#define LV_USE_WIN               0

#define LV_BUILD_EXAMPLES        0

#endif /* LV_CONF_H */
