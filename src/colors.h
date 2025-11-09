#ifndef __COLORS_H__
#define __COLORS_H__

/* colormap */
const unsigned short defaultcolors[] =	/* 0x0bgr */
{
//	black,  red,  green,yellow,  blue,magneta,cyan,  white, gray
	0x000, 0x00f, 0x0f0, 0x0ff, 0xf22, 0xf0f, 0xff0, 0xfff, 0x777, 0x000
};

/* 32bit colortable */
unsigned char bgra[][5] = { 
"\0\0\0\xFF\0", "\0\0\0\xFF\0", "\0\0\0\xFF\0", "\0\0\0\xFF\0",
"\0\0\0\xFF\0", "\0\0\0\xFF\0", "\0\0\0\xFF\0", "\0\0\0\xFF\0", "\0\0\0\0\0" };

#endif