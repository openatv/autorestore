FastRestore script for OpenATV

Restores image settings early during first boot of a newly flashed image,
rather then waiting for E2 to start.

FastRestore dramatically reduces the time needed for image upgrades.

## fbprogress

fbprogress shows the progress of the restore as a card at the bottom of
the boot logo. It is drawn with LVGL (submodule `lib/lvgl`, configured by
`include/lv_conf.h`) in DejaVu Sans (`fonts/*.c`, made by
`tools/mkfonts.sh`) and scales with the framebuffer. When it quits it gives
back the pixels under the card, the mode and the page of the framebuffer.

It reads lines from the pipe `/tmp/fbprogress_pipe`:

- `percent text`: the progress and the step, e.g. `40 Installing plugins 12 of 31: epgimport`
- `FAIL percent text`: the same, shown red for a moment for a failed package
- `SUB percent`: the progress within the step as a light line in the bar, `SUB -` hides it
- `QUIT`: close the card

Build with `make` (cross compile with `CC=...`), `git submodule update
--init` fetches LVGL first.
