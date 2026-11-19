/* Simulator-only runtime fault injection; never link into the app. */
#include <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR
#error Simulator only
#endif
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>

#define CAPACITY 256
/* Original-symbol calls in this image bypass its __interpose replacements. */
#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *new_function; const void *old_function; } \
    pair_##original = { (const void *)&replacement, (const void *)&original }

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int fd;
    bool occupied;
    unsigned in_flight;
    uint64_t identity, stopped_generation;
} ledger[CAPACITY];
static uint64_t next_identity, fault_generation, heartbeat;
static bool status_failed;

static struct {
    uint64_t shutdowns, rejected_connects, infrastructure_errors, shutdown_errors;
    int error_code;
    bool offline;
} counters;
static char flag_path[PATH_MAX];
static int status_fd = -1;
static atomic_bool enabled, stopping;
static pthread_t monitor_thread;
static bool thread_started;

static void infrastructure_error(int code) {
    counters.infrastructure_errors++;
    counters.error_code = code;
}

static bool fault_present(void) {
    struct stat info;
    if (lstat(flag_path, &info) == 0) return true;
    if (errno == ENOENT) return false;
    int saved = errno;
    if (counters.error_code != saved) infrastructure_error(saved);
    return true;
}

static int injected_socket(int domain, int type, int protocol) {
    if (!atomic_load(&enabled) || (domain != AF_INET && domain != AF_INET6))
        return socket(domain, type, protocol);
    pthread_mutex_lock(&lock);
    unsigned slot;
    for (slot = 0; slot < CAPACITY && ledger[slot].occupied; slot++) {}
    if (slot == CAPACITY) {
        infrastructure_error(ENOBUFS);
        pthread_mutex_unlock(&lock);
        errno = ENOBUFS;
        return -1;
    }
    int descriptor = socket(domain, type, protocol);
    int saved = errno;
    if (descriptor >= 0) {
        ledger[slot].fd = descriptor;
        ledger[slot].occupied = true;
        ledger[slot].in_flight = 0;
        ledger[slot].identity = ++next_identity;
        ledger[slot].stopped_generation = 0;
    }
    pthread_mutex_unlock(&lock);
    errno = saved;
    return descriptor;
}

static int injected_close(int descriptor) {
    if (!atomic_load(&enabled)) return close(descriptor);
    pthread_mutex_lock(&lock);
    int result = close(descriptor);
    int saved = errno;
    /* Darwin releases the descriptor even when close reports EINTR. */
    for (unsigned slot = 0; slot < CAPACITY; slot++)
        if (ledger[slot].occupied && ledger[slot].fd == descriptor)
            ledger[slot].occupied = false;
    pthread_mutex_unlock(&lock);
    errno = saved;
    return result;
}

static void observe_fault(bool offline) {
    if (offline && !counters.offline) fault_generation++;
    counters.offline = offline;
}

static void reconcile_socket(unsigned slot) {
    if (!counters.offline || !ledger[slot].occupied ||
        ledger[slot].stopped_generation == fault_generation) return;
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    if (getpeername(ledger[slot].fd, (struct sockaddr *)&address, &length) != 0) {
        if (errno != ENOTCONN && errno != EINVAL) infrastructure_error(errno);
        return;
    }
    if (shutdown(ledger[slot].fd, SHUT_RDWR) == 0) {
        counters.shutdowns++;
        if (ledger[slot].in_flight == 0)
            ledger[slot].stopped_generation = fault_generation;
    } else {
        counters.shutdown_errors++;
        infrastructure_error(errno);
    }
}

static bool begin_connect(int descriptor, uint64_t *identity) {
    int saved = errno;
    *identity = 0;
    if (!atomic_load(&enabled)) return false;
    bool network = false;
    pthread_mutex_lock(&lock);
    bool offline = fault_present();
    observe_fault(offline);
    for (unsigned slot = 0; slot < CAPACITY; slot++) {
        if (!ledger[slot].occupied || ledger[slot].fd != descriptor) continue;
        network = true;
        if (!offline) {
            ledger[slot].in_flight++;
            ledger[slot].stopped_generation = 0;
            *identity = ledger[slot].identity;
        }
        break;
    }
    if (!network) {
        struct sockaddr_storage address;
        socklen_t length = sizeof(address);
        if (getsockname(descriptor, (struct sockaddr *)&address, &length) == 0 &&
            (address.ss_family == AF_INET || address.ss_family == AF_INET6)) {
            network = true;
            infrastructure_error(ENOTSUP);
        }
    }
    if (network && offline) counters.rejected_connects++;
    pthread_mutex_unlock(&lock);
    errno = network && offline ? ENETDOWN : saved;
    return network && offline;
}

static void finish_connect(int descriptor, uint64_t identity) {
    if (!identity) return;
    int saved = errno;
    pthread_mutex_lock(&lock);
    bool offline = fault_present();
    observe_fault(offline);
    for (unsigned slot = 0; slot < CAPACITY; slot++) {
        if (!ledger[slot].occupied || ledger[slot].fd != descriptor ||
            ledger[slot].identity != identity) continue;
        ledger[slot].in_flight--;
        ledger[slot].stopped_generation = 0;
        reconcile_socket(slot);
        break;
    }
    pthread_mutex_unlock(&lock);
    errno = saved;
}

static int injected_connect(int descriptor, const struct sockaddr *address, socklen_t length) {
    uint64_t identity;
    if (begin_connect(descriptor, &identity)) return -1;
    int result = connect(descriptor, address, length);
    finish_connect(descriptor, identity);
    return result;
}

static int injected_connectx(int descriptor, const sa_endpoints_t *endpoints,
                            sae_associd_t association, unsigned int flags,
                            const struct iovec *data, unsigned int count,
                            size_t *written, sae_connid_t *connection) {
    uint64_t identity;
    if (begin_connect(descriptor, &identity)) return -1;
    int result = connectx(descriptor, endpoints, association, flags, data, count, written, connection);
    finish_connect(descriptor, identity);
    return result;
}

static void *monitor(void *unused) {
    (void)unused;
    while (!atomic_load(&stopping)) {
        char status[768];
        pthread_mutex_lock(&lock);
        bool offline = fault_present();
        observe_fault(offline);
        for (unsigned slot = 0; slot < CAPACITY; slot++) reconcile_socket(slot);
        heartbeat++;
        int length = snprintf(status, sizeof(status),
            "{\"schema\":2,\"capacity\":256,\"offline\":%s,\"shutdowns\":%llu,"
            "\"heartbeat\":%llu,\"fault_generation\":%llu,\"terminal_error\":%s,"
            "\"rejected_connects\":%llu,\"infrastructure_errors\":%llu,"
            "\"shutdown_errors\":%llu,\"error_code\":%d}\n",
            counters.offline ? "true" : "false",
            (unsigned long long)counters.shutdowns,
            (unsigned long long)heartbeat, (unsigned long long)fault_generation,
            counters.infrastructure_errors ? "true" : "false",
            (unsigned long long)counters.rejected_connects,
            (unsigned long long)counters.infrastructure_errors,
            (unsigned long long)counters.shutdown_errors, counters.error_code);
        pthread_mutex_unlock(&lock);
        ssize_t written = pwrite(status_fd, status, (size_t)length, 0);
        int failure = written != length ? (written < 0 ? errno : EIO) : 0;
        if (!failure && ftruncate(status_fd, length) != 0) failure = errno;
        if (failure) {
            pthread_mutex_lock(&lock);
            infrastructure_error(failure);
            pthread_mutex_unlock(&lock);
            if (!status_failed) {
                const char message[] = "simulator_network_fault: terminal status write failure; reject acceptance; monitoring continues\n";
                (void)write(STDERR_FILENO, message, sizeof(message) - 1);
                status_failed = true;
            }
        }
        struct timespec delay = { .tv_sec = 0, .tv_nsec = 100000000 };
        nanosleep(&delay, NULL);
    }
    return NULL;
}

static bool private_paths(const char *flag, const char *status) {
    char parent[PATH_MAX], other[PATH_MAX], canonical[PATH_MAX];
    if (strlen(flag) >= sizeof(parent) || strlen(status) >= sizeof(other)) return false;
    strcpy(parent, flag);
    strcpy(other, status);
    char *flag_name = strrchr(parent, '/');
    char *status_name = strrchr(other, '/');
    if (!flag_name || !status_name || !flag_name[1] || !status_name[1] ||
        strcmp(flag_name + 1, ".") == 0 || strcmp(flag_name + 1, "..") == 0 ||
        strcmp(status_name + 1, ".") == 0 || strcmp(status_name + 1, "..") == 0) return false;
    *flag_name = '\0';
    *status_name = '\0';
    struct stat info;
    return strcmp(parent, other) == 0 && realpath(parent, canonical) != NULL &&
        strcmp(parent, canonical) == 0 && stat(parent, &info) == 0 &&
        S_ISDIR(info.st_mode) && info.st_uid == getuid() && (info.st_mode & 077) == 0;
}

static void before_fork(void) {
    pthread_mutex_lock(&lock);
    infrastructure_error(ENOTSUP);
}

static void after_fork_parent(void) { pthread_mutex_unlock(&lock); }

static void after_fork_child(void) {
    atomic_store(&enabled, false);
    thread_started = false;
    if (status_fd >= 0) close(status_fd);
    status_fd = -1;
    pthread_mutex_unlock(&lock);
    const char message[] = "simulator_network_fault: fork unsupported; child injection disabled\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
}

__attribute__((constructor)) static void start(void) {
    const char *flag = getenv("JOURNAL_TEST_NETWORK_FAULT_FLAG");
    const char *status = getenv("JOURNAL_TEST_NETWORK_FAULT_STATUS");
    if (!flag && !status) return;
    if (!flag || !status || flag[0] != '/' || status[0] != '/' ||
        strcmp(flag, status) == 0 || !private_paths(flag, status)) goto failed;
    memcpy(flag_path, flag, strlen(flag) + 1);
    /* Require a fresh status file; never overwrite another task's data. */
    status_fd = open(status, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (status_fd < 0) goto failed;
    if (pthread_atfork(before_fork, after_fork_parent, after_fork_child) != 0) {
        close(status_fd);
        status_fd = -1;
        goto failed;
    }
    atomic_store(&enabled, true);
    int result = pthread_create(&monitor_thread, NULL, monitor, NULL);
    if (result != 0) {
        atomic_store(&enabled, false);
        close(status_fd);
        status_fd = -1;
        goto failed;
    }
    thread_started = true;
    return;
failed:;
    const char message[] = "simulator_network_fault: initialization failed; injection not ready\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
}

__attribute__((destructor)) static void stop(void) {
    if (!thread_started) return;
    atomic_store(&stopping, true);
    pthread_join(monitor_thread, NULL);
    close(status_fd);
}

INTERPOSE(injected_socket, socket);
INTERPOSE(injected_close, close);
INTERPOSE(injected_connect, connect);
INTERPOSE(injected_connectx, connectx);
