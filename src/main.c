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
#include <sys/ioctl.h>
#include <libgen.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/select.h>
#include "main.h"

#define PIPE_PATH "/tmp/fbprogress_pipe"

int main(int argc, char **argv) {

	mkfifo(PIPE_PATH, 0666);

    int fd = open(PIPE_PATH, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    char cfg_path[512];
    char exe_path[512];
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path)-1);
    if (len != -1) {
        exe_path[len] = '\0';
        snprintf(cfg_path, sizeof(cfg_path), "%s/fbprogress.cfg", dirname(exe_path));
    } else {
        strcpy(cfg_path, "fbprogress.cfg"); // fallback
    }

    load_config(cfg_path);

	init_framebuffer(2);
	show_main_window();
	set_step_text("Start....");

	char buffer[256];

    while (1) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(fd, &readfds);

        int ret = select(fd + 1, &readfds, NULL, NULL, NULL);
        if (ret < 0) {
//            perror("select");
            break;
        }

        if (FD_ISSET(fd, &readfds)) {
            ssize_t n = read(fd, buffer, sizeof(buffer)-1);
            if (n > 0) {
                buffer[n] = '\0';
                char *line = strtok(buffer, "\n");
				if (strcmp(line, "QUIT") == 0)
					break;
                while (line) {
                    int percent;
                    char text[200];
                    printf("Received: %s\n", line);
                    if (sscanf(line, "%d %[^\n]", &percent, text) == 2) {
                        set_step_text(text);
                        set_step_progress(percent);
                    }
                    line = strtok(NULL, "\n");
                }
            } else if (n == 0) {
                close(fd);
                fd = open(PIPE_PATH, O_RDONLY | O_NONBLOCK);
                if (fd < 0) {
					break;
//                    perror("open");
                }
            }
        }
    }

    close(fd);
	unlink(PIPE_PATH);
	close_framebuffer();

	return 0;
}