// Behavioural probe: does a picture-grade filter change pixels under libmpv's
// SW render API (what Opal uses)? Usage:
//   mpv_eq_probe <clip> <hwdec> [spec ...]
// For each spec ("" = no filter) applies `vf @opal-eq:lavfi=[spec]` exactly as
// player.applyVideoGrade does, renders one 320x180 bgr0 frame and prints
//   "<index> mean=<m> chroma=<c>"
// Build: cc -o mpv_eq_probe mpv_eq_probe.c -I<inc> -L<lib> -lmpv
#include <mpv/client.h>
#include <mpv/render.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void settle(mpv_handle *m, int min_iter) {
  for (int k = 0; k < 60; k++) {
    mpv_event *e = mpv_wait_event(m, 0.05);
    if (e->event_id == MPV_EVENT_NONE && k > min_iter) break;
  }
}

int main(int argc, char **argv) {
  if (argc < 3) return 2;
  mpv_handle *m = mpv_create();
  mpv_set_option_string(m, "vo", "libmpv");
  mpv_set_option_string(m, "pause", "yes");
  mpv_set_option_string(m, "hwdec", argv[2]);
  mpv_set_option_string(m, "audio", "no");
  mpv_initialize(m);
  mpv_render_param pp[] = {{MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_SW}, {0}};
  mpv_render_context *rc;
  if (mpv_render_context_create(&rc, m, pp) < 0) { puts("rc fail"); return 1; }
  const char *cmd[] = {"loadfile", argv[1], NULL};
  mpv_command(m, cmd);
  for (;;) {
    mpv_event *e = mpv_wait_event(m, 5);
    if (e->event_id == MPV_EVENT_PLAYBACK_RESTART) break;
    if (e->event_id == MPV_EVENT_NONE) { puts("timeout"); return 1; }
  }
  int w = 320, h = 180;
  size_t st = (size_t)w * 4;
  unsigned char *buf = malloc(st * h);
  int sz[2] = {w, h};
  char *hw = mpv_get_property_string(m, "hwdec-current");
  printf("hwdec-current=%s\n", hw ? hw : "?");
  for (int i = 3; i < argc; i++) {
    const char *rm[] = {"vf", "remove", "@opal-eq", NULL};
    mpv_command(m, rm);
    if (argv[i][0]) {
      char arg[768];
      snprintf(arg, sizeof arg, "@opal-eq:lavfi=[%s]", argv[i]);
      const char *add[] = {"vf", "add", arg, NULL};
      int r = mpv_command(m, add);
      if (r < 0) printf("vf add err %s\n", mpv_error_string(r));
    }
    settle(m, 10);
    mpv_render_param rp[] = {{MPV_RENDER_PARAM_SW_SIZE, sz}, {MPV_RENDER_PARAM_SW_FORMAT, (void *)"bgr0"},
                             {MPV_RENDER_PARAM_SW_STRIDE, &st}, {MPV_RENDER_PARAM_SW_POINTER, buf}, {0}};
    int r = mpv_render_context_render(rc, rp);
    if (r < 0) printf("render err %s\n", mpv_error_string(r));
    double sum = 0, sat = 0;
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) {
        unsigned char *q = buf + y * st + x * 4;
        int b = q[0], g = q[1], rr = q[2];
        int mx = rr > g ? (rr > b ? rr : b) : (g > b ? g : b);
        int mn = rr < g ? (rr < b ? rr : b) : (g < b ? g : b);
        sum += (rr + g + b) / 3.0;
        sat += mx - mn;
      }
    printf("%d mean=%.2f chroma=%.2f\n", i - 3, sum / (w * h), sat / (w * h));
  }
  mpv_render_context_free(rc);
  mpv_terminate_destroy(m);
  return 0;
}
