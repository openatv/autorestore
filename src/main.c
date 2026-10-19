/*
 * fbprogress (c) 2025 jbleyel
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 *
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <errno.h>
#include <signal.h>
#include "main.h"

#define PIPE_PATH "/tmp/fbprogress_pipe"

static volatile sig_atomic_t g_stop_requested = 0;

static void handle_signal(int sig)
{
	(void)sig;
	g_stop_requested = 1;
}

static void install_signal_handlers(void)
{
	struct sigaction action;

	memset(&action, 0, sizeof(action));
	action.sa_handler = handle_signal;
	sigemptyset(&action.sa_mask);
	sigaction(SIGTERM, &action, NULL);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGHUP, &action, NULL);
}

int main(void) {
	int fd = -1;
	int exit_code = 0;

	install_signal_handlers();

	if (mkfifo(PIPE_PATH, 0666) < 0 && errno != EEXIST) {
		perror("mkfifo");
		return 1;
	}

    fd = open(PIPE_PATH, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open");
		unlink(PIPE_PATH);
        return 1;
    }

	if (!init_framebuffer()) {
		exit_code = 1;
		goto cleanup;
	}
	set_progress(0, "Starting", 0);

	char buffer[256];

    while (!g_stop_requested) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(fd, &readfds);

        struct timeval timeout = {0, 250000};  /* For the running time and texts held back by the redraw rate. */
        int ret = select(fd + 1, &readfds, NULL, NULL, &timeout);
        tick_framebuffer();
        if (ret < 0) {
			if (errno == EINTR)
				continue;
			perror("select");
			exit_code = 1;
            break;
        }

        if (FD_ISSET(fd, &readfds)) {
            ssize_t n = read(fd, buffer, sizeof(buffer)-1);
            if (n > 0) {
                buffer[n] = '\0';
                char *line = strtok(buffer, "\n");
                while (line) {
					if (strcmp(line, "QUIT") == 0) {
						g_stop_requested = 1;
						break;
					}
					if (strncmp(line, "SUB ", 4) == 0) {  /* "SUB 39", "SUB -" hides it. */
						set_sub_progress(line[4] == '-' ? -1 : atoi(line + 4));
						line = strtok(NULL, "\n");
						continue;
					}
                    int percent;
                    char text[200];
                    printf("Received: %s\n", line);
                    int failed = strncmp(line, "FAIL ", 5) == 0;  /* "FAIL 70 text": shown red for a moment. */
                    if (sscanf(failed ? line + 5 : line, "%d %199[^\n]", &percent, text) == 2)
                        set_progress(percent, text, failed);
                    line = strtok(NULL, "\n");
                }
            } else if (n == 0) {
                close(fd);
                fd = open(PIPE_PATH, O_RDONLY | O_NONBLOCK);
                if (fd < 0) {
					exit_code = 1;
					break;
//                    perror("open");
                }
            }
        }
    }

cleanup:
	if (fd >= 0)
		close(fd);
	unlink(PIPE_PATH);
	close_framebuffer();

	return exit_code;
}
