/* A host of the discovery library (spec frontends/linux-desktop.md §6.2): it
   asks twice, prints what it was given, and checks that starting the library
   left the process as it was. */
#define _GNU_SOURCE
#include <locale.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "tsync_mounts.h"

extern char **environ;

typedef struct {
  char text[4096];
  size_t used;
} answer;

static void record(void *context, const char *mount_point,
                   size_t mount_point_length, const char *socket,
                   size_t socket_length) {
  answer *a = context;
  a->used += snprintf(a->text + a->used, sizeof a->text - a->used,
                      "  [%.*s] [%.*s]\n", (int)mount_point_length, mount_point,
                      (int)socket_length, socket);
}

static unsigned long environment_digest(void) {
  unsigned long digest = 5381;
  for (char **variable = environ; *variable != NULL; variable++)
    for (char *c = *variable; *c; c++)
      digest = digest * 33 + (unsigned char)*c;
  return digest;
}

int main(int argc, char **argv) {
  const char *label = argc > 1 ? argv[1] : "host";
  struct sigaction before[NSIG], after;
  for (int signal = 1; signal < NSIG; signal++)
    sigaction(signal, NULL, &before[signal]);
  stack_t stack_before, stack_after;
  sigaltstack(NULL, &stack_before);
  char directory_before[4096], directory_after[4096], locale_before[256];
  getcwd(directory_before, sizeof directory_before);
  snprintf(locale_before, sizeof locale_before, "%s", setlocale(LC_ALL, NULL));
  unsigned long environment_before = environment_digest();

  answer first = {0}, second = {0};
  int first_count = tsync_mounts_query(record, &first);
  int second_count = tsync_mounts_query(record, &second);

  int changed = 0;
  for (int signal = 1; signal < NSIG; signal++)
    if (sigaction(signal, NULL, &after) == 0 &&
        (after.sa_handler != before[signal].sa_handler ||
         after.sa_flags != before[signal].sa_flags))
      changed++;
  sigaltstack(NULL, &stack_after);
  getcwd(directory_after, sizeof directory_after);

  printf("== %s: %d pairs\n%s", label, first_count, first.text);
  printf("  asked again: %s\n",
         first_count == second_count && strcmp(first.text, second.text) == 0
             ? "the same answer"
             : "ANOTHER ANSWER");
  printf("  signal dispositions changed: %d\n", changed);
  printf("  signal stack, directory, locale, environment unchanged: %s\n",
         stack_before.ss_sp == stack_after.ss_sp &&
                 stack_before.ss_flags == stack_after.ss_flags &&
                 strcmp(directory_before, directory_after) == 0 &&
                 strcmp(locale_before, setlocale(LC_ALL, NULL)) == 0 &&
                 environment_before == environment_digest()
             ? "yes"
             : "NO");
  return first_count < 0;
}
