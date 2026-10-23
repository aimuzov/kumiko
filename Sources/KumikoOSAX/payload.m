#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <pthread.h>
#include <pwd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "common.h"

// Runs inside Dock. Dock's connection to the window server may change any window, which is all
// kumiko needs it for: a socket that takes requests and applies them as Dock.

extern int SLSMainConnectionID(void);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);

// The window server tag that leaves a window without its shadow.
static const uint64_t no_shadow_tag = 1 << 3;

static int server_fd = -1;

static bool read_exactly(int fd, void *buffer, size_t length) {
	size_t done = 0;
	while (done < length) {
		ssize_t n = read(fd, (char *) buffer + done, length - done);
		if (n <= 0) return false;
		done += n;
	}
	return true;
}

static void handle(int fd, const uint8_t *message, int16_t length) {
	if (length < 1) return;

	switch (message[0]) {
	case SA_OPCODE_HANDSHAKE: {
		const char reply[] = SA_VERSION "\n";
		write(fd, reply, sizeof(reply) - 1);
	} break;
	case SA_OPCODE_WINDOW_SHADOW: {
		if (length < 1 + sizeof(uint32_t) + 1) return;

		uint32_t wid;
		memcpy(&wid, message + 1, sizeof(wid));
		bool on = message[1 + sizeof(wid)] != 0;

		uint64_t tags = no_shadow_tag;
		if (on) {
			SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64);
		} else {
			SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64);
		}
	} break;
	}
}

static void *serve(void *unused) {
	for (;;) {
		int fd = accept(server_fd, NULL, NULL);
		if (fd == -1) continue;

		int16_t length = 0;
		uint8_t message[0x1000];
		if (read_exactly(fd, &length, sizeof(length)) && length > 0 && length <= (int16_t) sizeof(message) &&
		    read_exactly(fd, message, length)) {
			handle(fd, message, length);
		}

		close(fd);
	}
	return NULL;
}

__attribute__((constructor)) static void load(void) {
	struct passwd *user = getpwuid(getuid());
	if (!user) {
		NSLog(@"[kumiko-sa] no user, not listening");
		return;
	}

	struct sockaddr_un address = {.sun_family = AF_UNIX};
	snprintf(address.sun_path, sizeof(address.sun_path), SA_SOCKET_PATH_FMT, user->pw_name);
	unlink(address.sun_path);

	server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (server_fd == -1 || bind(server_fd, (struct sockaddr *) &address, sizeof(address)) == -1 ||
	    chmod(address.sun_path, 0600) != 0 || listen(server_fd, SOMAXCONN) == -1) {
		NSLog(@"[kumiko-sa] cannot listen on %s", address.sun_path);
		return;
	}

	pthread_t thread;
	pthread_create(&thread, NULL, serve, NULL);
	NSLog(@"[kumiko-sa] version %s listening on %s", SA_VERSION, address.sun_path);
}
