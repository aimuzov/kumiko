#ifndef KUMIKO_SA_COMMON_H
#define KUMIKO_SA_COMMON_H

// Shared with ScriptingAddition.swift: a message is an int16 length, then the opcode and its
// arguments, little endian.

#define SA_SOCKET_PATH_FMT "/tmp/kumiko-sa_%s.socket"
#define SA_VERSION         "1"

enum sa_opcode {
	// Answers with the payload version and a newline.
	SA_OPCODE_HANDSHAKE     = 0x01,
	// uint32 window id, uint8 whether the window has a shadow.
	SA_OPCODE_WINDOW_SHADOW = 0x02,
};

#endif
