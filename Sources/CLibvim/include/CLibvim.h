// The part of libvim's API kumiko uses, declared with plain C types. libvim.h itself pulls in all
// of Vim's headers and macros, which Swift cannot import cleanly; these declarations match the
// ones in Vendor/libvim/src/libvim.h and structs.h.

#ifndef CLIBVIM_H
#define CLIBVIM_H

#include <stddef.h>

typedef long vim_linenr;
typedef int vim_colnr;

typedef struct {
	vim_linenr lnum;
	vim_colnr col;
	vim_colnr coladd;
} vim_pos;

/// Vim's buf_T, kept opaque.
typedef void *vim_buffer;

// Mode bits of vimGetMode(), from vim.h.
#define VIM_NORMAL 0x01
#define VIM_VISUAL 0x02
#define VIM_OP_PENDING 0x04
#define VIM_CMDLINE 0x08
#define VIM_INSERT 0x10
#define VIM_REPLACE_FLAG 0x40

void vimInit(int argc, char **argv);

void vimInput(unsigned char *input);
void vimKey(unsigned char *key);
void vimExecute(unsigned char *cmd);
int vimGetMode(void);

vim_buffer vimBufferOpen(unsigned char *path, vim_linenr lnum, int flags);
vim_buffer vimBufferGetCurrent(void);
unsigned char *vimBufferGetLine(vim_buffer buf, vim_linenr lnum);
size_t vimBufferGetLineCount(vim_buffer buf);
void vimBufferSetLines(vim_buffer buf, vim_linenr start, vim_linenr end, unsigned char **lines, int count);

vim_pos vimCursorGetPosition(void);
void vimCursorSetPosition(vim_pos pos);

int vimVisualGetType(void);
int vimVisualIsActive(void);
void vimVisualGetRange(vim_pos *start, vim_pos *end);

unsigned char *vimCommandLineGetText(void);

#endif
