#include <errno.h>
#include <spawn.h>
#include <sys/types.h>
#include <unistd.h>

/*
 * iOS applications cannot create child processes. Resolve the OCaml Unix
 * runtime's otherwise-unused process imports inside the private framework so
 * the shipped binary never imports process-creation APIs from libSystem.
 */

pid_t fork(void) {
  errno = ENOTSUP;
  return -1;
}

int execv(const char *path, char *const argv[]) {
  (void)path;
  (void)argv;
  errno = ENOTSUP;
  return -1;
}

int execve(const char *path, char *const argv[], char *const envp[]) {
  (void)path;
  (void)argv;
  (void)envp;
  errno = ENOTSUP;
  return -1;
}

int execvp(const char *file, char *const argv[]) {
  (void)file;
  (void)argv;
  errno = ENOTSUP;
  return -1;
}

int posix_spawn(
    pid_t *restrict pid,
    const char *restrict path,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *restrict attrp,
    char *const argv[restrict],
    char *const envp[restrict]) {
  (void)pid;
  (void)path;
  (void)file_actions;
  (void)attrp;
  (void)argv;
  (void)envp;
  return ENOTSUP;
}

int posix_spawnp(
    pid_t *restrict pid,
    const char *restrict file,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *restrict attrp,
    char *const argv[restrict],
    char *const envp[restrict]) {
  (void)pid;
  (void)file;
  (void)file_actions;
  (void)attrp;
  (void)argv;
  (void)envp;
  return ENOTSUP;
}

int posix_spawn_file_actions_init(posix_spawn_file_actions_t *file_actions) {
  (void)file_actions;
  return ENOTSUP;
}

int posix_spawn_file_actions_destroy(
    posix_spawn_file_actions_t *file_actions) {
  (void)file_actions;
  return ENOTSUP;
}

int posix_spawn_file_actions_addclose(
    posix_spawn_file_actions_t *file_actions,
    int file_descriptor) {
  (void)file_actions;
  (void)file_descriptor;
  return ENOTSUP;
}

int posix_spawn_file_actions_adddup2(
    posix_spawn_file_actions_t *file_actions,
    int file_descriptor,
    int new_file_descriptor) {
  (void)file_actions;
  (void)file_descriptor;
  (void)new_file_descriptor;
  return ENOTSUP;
}
