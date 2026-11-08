/* Development-only Linux process measurement, not a compiler/runtime dependency.
 * Small C parent avoids inheriting Python's RSS into the measured child's fork.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t owned_child, timed_out;
static void timeout_child(int signal_number) {
    (void)signal_number;
    timed_out = 1;
    if (owned_child > 0) kill(-(pid_t)owned_child, SIGKILL);
}
int main(int argc, char **argv) {
    if (argc < 6) return 64;
    int cpu = atoi(argv[1]);
    if (cpu < 0 || cpu >= CPU_SETSIZE) return 64;
    struct timespec begin, end;
    struct rusage usage;
    struct sigaction action = {.sa_handler = timeout_child};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, NULL) < 0) return 125;
    clock_gettime(CLOCK_MONOTONIC, &begin);
    pid_t child = fork();
    if (child < 0) return 125;
    if (!child) {
        if (setpgid(0, 0) < 0) _exit(125);
        cpu_set_t affinity;
        CPU_ZERO(&affinity);
        CPU_SET(cpu, &affinity);
        if (sched_setaffinity(0, sizeof affinity, &affinity) < 0) _exit(125);
        struct rlimit core = {0, 0}, time = {60, 60};
        if (setrlimit(RLIMIT_CORE, &core) < 0 || setrlimit(RLIMIT_CPU, &time) < 0) _exit(125);
        for (int fd = 1; fd <= 2; fd++) {
            int file = open(argv[fd + 2], O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (file < 0 || dup2(file, fd) < 0) _exit(125);
            close(file);
        }
        execv(argv[5], argv + 5);
        _exit(125);
    }
    owned_child = child;
    alarm(120);
    int status;
    while (wait4(child, &status, 0, &usage) < 0) if (errno != EINTR) return 125;
    alarm(0);
    clock_gettime(CLOCK_MONOTONIC, &end);
    FILE *report = fopen(argv[2], "wx");
    if (!report) return 125;
    double wall = end.tv_sec - begin.tv_sec + (end.tv_nsec - begin.tv_nsec) / 1e9;
    double user = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6;
    double system = usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
    fprintf(report, "{\"wallSeconds\":%.9f,\"userSeconds\":%.6f,\"systemSeconds\":%.6f,"
                    "\"peakRSSKiB\":%ld,\"exitCode\":%d,\"timedOut\":%s}\n",
            wall, user, system, usage.ru_maxrss,
            WIFEXITED(status) ? WEXITSTATUS(status) : -WTERMSIG(status),
            timed_out ? "true" : "false");
    return fclose(report) ? 125 : 0;
}
