#ifndef __MAIN_H__
#define __MAIN_H__

int init_framebuffer(void);
void set_progress(int percent, const char *text, int failed);
void set_sub_progress(int percent);
void tick_framebuffer(void);
void close_framebuffer(void);

#endif
