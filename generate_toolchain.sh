#!/usr/bin/env bash

# Generate toolchain.tgz in CWD

set -e

if [[ -e "toolchain" ]]; then
    echo "Dir toolchain/ already exists"
    exit 1
fi

mkdir -p toolchain/{bin,lib}

cp -r -L /opt/exodus/bundles/*/lib/x86_64-linux-gnu/* toolchain/lib/

cp -r -L /opt/exodus/bundles/*/usr/lib/x86_64-linux-gnu/* toolchain/lib/

cp -L \
      /lib/x86_64-linux-gnu/libresolv.so.2 \
      /lib/x86_64-linux-gnu/libnss_nisplus.so.2 \
      /lib/x86_64-linux-gnu/libnss_compat.so.2 \
      /lib/x86_64-linux-gnu/libnss_dns.so.2 \
      /lib/x86_64-linux-gnu/libnss_files.so.2 \
      /lib/x86_64-linux-gnu/libnss_hesiod.so.2 \
      /lib/x86_64-linux-gnu/libnss_nis.so.2 \
    toolchain/lib/

# Provide gperf CPU profiler
cp -L /usr/lib/x86_64-linux-gnu/libprofiler.so.0.4.8 toolchain/lib/libprofiler.so
cp -L /usr/lib/x86_64-linux-gnu/libunwind.so.8 toolchain/lib/

gcc -shared -fPIC /disable_ld_preload.c -o toolchain/lib/disable_ld_preload.so -ldl

tar xzf /opt/patchelf-0.14.3-x86_64.tar.gz ./bin/patchelf --strip-components=2

for lib in toolchain/lib/*; do
    if [[ ! "$lib" = "toolchain/lib/libc.so.6"* ]]; then
        ./patchelf --set-rpath '$ORIGIN' "$lib"
    fi
done

for f in /opt/exodus/bundles/*/usr/bin/*-x; do
    p=$(basename $f)
    g=${p::-2}
    cp $f toolchain/bin/$g
done

cp /usr/lib/llvm-${LLVM_VERSION}/bin/llvm-symbolizer toolchain/bin/

for bin in toolchain/bin/*; do
    ./patchelf --set-interpreter "$PWD/toolchain/lib/ld-linux-x86-64.so.2" --set-rpath '$ORIGIN/../lib' "$bin"
done

ln -sf ld.bfd toolchain/bin/ld
ln -sf ld.bfd toolchain/bin/x86_64-pc-linux-gnu-ld # clang tries to find this linker
ln -sf lld-${LLVM_VERSION} toolchain/bin/ld.lld
ln -sf lld-${LLVM_VERSION} toolchain/bin/ld.lld-${LLVM_VERSION}
ln -sf clang-${LLVM_VERSION} toolchain/bin/clang++-${LLVM_VERSION}
ln -sf llvm-objcopy-${LLVM_VERSION} toolchain/bin/objcopy
ln -sf llvm-objdump-${LLVM_VERSION} toolchain/bin/objdump
ln -sf clang-cpp-${LLVM_VERSION} toolchain/bin/cpp
ln -sf llvm-ar-${LLVM_VERSION} toolchain/bin/ar
ln -sf llvm-ranlib-${LLVM_VERSION} toolchain/bin/ranlib
ln -sf llvm-nm-${LLVM_VERSION} toolchain/bin/nm
ln -sf lldb-${LLVM_VERSION} toolchain/bin/lldb
ln -sf clangd-${LLVM_VERSION} toolchain/bin/clangd
ln -sf clang-tidy-${LLVM_VERSION} toolchain/bin/clang-tidy
ln -sf clang-format-${LLVM_VERSION} toolchain/bin/clang-format
ln -sf gcc toolchain/bin/cc
mv toolchain/bin/lldb-server-${LLVM_VERSION} toolchain/bin/lldb-server-${LLVM_VERSION}.0.1

# ln -sf gcc-ranlib-11 toolchain/bin/ranlib
# ln -sf gcc-ar-11 toolchain/bin/ar
# ln -sf gcc-nm-11 toolchain/bin/nm

# gcc-ar-11
# gcc-nm-11
# gcc-ranlib-11

cp -L /opt/exodus/bundles/*/usr/bin/linker-* toolchain/lib/ld-linux-x86-64.so.2

tar xzf /opt/cmake-3.22.1-linux-x86_64.tar.gz --strip-components=1 --exclude='*/doc' --exclude='*/man' -C toolchain

# JDK and Maven are too large
# mkdir toolchain/apache-maven-3.8.4
# tar xzf /opt/apache-maven-3.8.4-bin.tar.gz --strip-components=1 -C toolchain/apache-maven-3.8.4

# mkdir toolchain/openjdk-11.0.2
# tar xzf /opt/openjdk-11.0.2_linux-x64_bin.tar.gz --strip-components=1 -C toolchain/openjdk-11.0.2

# Setup sysroot

mkdir -p toolchain/usr/lib

cp -r --parents \
    /usr/include/alloca.h \
    /usr/include/ansidecl.h \
    /usr/include/ar.h \
    /usr/include/argz.h \
    /usr/include/arpa/inet.h \
    /usr/include/arpa/nameser.h \
    /usr/include/arpa/nameser_compat.h \
    /usr/include/asm-generic/bitsperlong.h \
    /usr/include/asm-generic/errno-base.h \
    /usr/include/asm-generic/errno.h \
    /usr/include/asm-generic/hugetlb_encode.h \
    /usr/include/asm-generic/int-ll64.h \
    /usr/include/asm-generic/ioctl.h \
    /usr/include/asm-generic/ioctls.h \
    /usr/include/asm-generic/mman-common.h \
    /usr/include/asm-generic/mman.h \
    /usr/include/asm-generic/param.h \
    /usr/include/asm-generic/posix_types.h \
    /usr/include/asm-generic/socket.h \
    /usr/include/asm-generic/sockios.h \
    /usr/include/asm-generic/types.h \
    /usr/include/assert.h \
    /usr/include/bfd.h \
    /usr/include/byteswap.h \
    /usr/include/ctype.h \
    /usr/include/complex.h \
    /usr/include/dirent.h \
    /usr/include/dlfcn.h \
    /usr/include/elf.h \
    /usr/include/endian.h \
    /usr/include/errno.h \
    /usr/include/execinfo.h \
    /usr/include/fcntl.h \
    /usr/include/features.h \
    /usr/include/fenv.h \
    /usr/include/fnmatch.h \
    /usr/include/getopt.h \
    /usr/include/glob.h \
    /usr/include/grp.h \
    /usr/include/iconv.h \
    /usr/include/ifaddrs.h \
    /usr/include/inttypes.h \
    /usr/include/langinfo.h \
    /usr/include/libgen.h \
    /usr/include/libiberty/libiberty.h \
    /usr/include/libintl.h \
    /usr/include/limits.h \
    /usr/include/link.h \
    /usr/include/linux \
    /usr/include/locale.h \
    /usr/include/malloc.h \
    /usr/include/math.h \
    /usr/include/memory.h \
    /usr/include/mntent.h \
    /usr/include/monetary.h \
    /usr/include/net/ethernet.h \
    /usr/include/net/if.h \
    /usr/include/net/if_arp.h \
    /usr/include/netdb.h \
    /usr/include/netinet/in.h \
    /usr/include/netinet/in_systm.h \
    /usr/include/netinet/ip.h \
    /usr/include/netinet/tcp.h \
    /usr/include/netinet/udp.h \
    /usr/include/netpacket/packet.h \
    /usr/include/nl_types.h \
    /usr/include/paths.h \
    /usr/include/poll.h \
    /usr/include/pthread.h \
    /usr/include/pwd.h \
    /usr/include/regex.h \
    /usr/include/resolv.h \
    /usr/include/rpc/netdb.h \
    /usr/include/sched.h \
    /usr/include/search.h \
    /usr/include/semaphore.h \
    /usr/include/setjmp.h \
    /usr/include/shadow.h \
    /usr/include/signal.h \
    /usr/include/spawn.h \
    /usr/include/stab.h \
    /usr/include/stdc-predef.h \
    /usr/include/stdint.h \
    /usr/include/stdio.h \
    /usr/include/stdlib.h \
    /usr/include/string.h \
    /usr/include/strings.h \
    /usr/include/stropts.h \
    /usr/include/symcat.h \
    /usr/include/syscall.h \
    /usr/include/sysexits.h \
    /usr/include/syslog.h \
    /usr/include/termios.h \
    /usr/include/time.h \
    /usr/include/ucontext.h \
    /usr/include/unistd.h \
    /usr/include/utime.h \
    /usr/include/wchar.h \
    /usr/include/wctype.h \
    /usr/include/wordexp.h \
    /usr/include/x86_64-linux-gnu/a.out.h \
    /usr/include/x86_64-linux-gnu/asm/a.out.h \
    /usr/include/x86_64-linux-gnu/asm/bitsperlong.h \
    /usr/include/x86_64-linux-gnu/asm/byteorder.h \
    /usr/include/x86_64-linux-gnu/asm/errno.h \
    /usr/include/x86_64-linux-gnu/asm/ioctl.h \
    /usr/include/x86_64-linux-gnu/asm/ioctls.h \
    /usr/include/x86_64-linux-gnu/asm/mman.h \
    /usr/include/x86_64-linux-gnu/asm/param.h \
    /usr/include/x86_64-linux-gnu/asm/posix_types.h \
    /usr/include/x86_64-linux-gnu/asm/posix_types_64.h \
    /usr/include/x86_64-linux-gnu/asm/processor-flags.h \
    /usr/include/x86_64-linux-gnu/asm/ptrace.h \
    /usr/include/x86_64-linux-gnu/asm/ptrace-abi.h \
    /usr/include/x86_64-linux-gnu/asm/socket.h \
    /usr/include/x86_64-linux-gnu/asm/sockios.h \
    /usr/include/x86_64-linux-gnu/asm/swab.h \
    /usr/include/x86_64-linux-gnu/asm/types.h \
    /usr/include/x86_64-linux-gnu/asm/unistd.h \
    /usr/include/x86_64-linux-gnu/asm/unistd_64.h \
    /usr/include/x86_64-linux-gnu/bits/_G_config.h \
    /usr/include/x86_64-linux-gnu/bits/a.out.h \
    /usr/include/x86_64-linux-gnu/bits/auxv.h \
    /usr/include/x86_64-linux-gnu/bits/byteswap-16.h \
    /usr/include/x86_64-linux-gnu/bits/byteswap.h \
    /usr/include/x86_64-linux-gnu/bits/cmathcalls.h \
    /usr/include/x86_64-linux-gnu/bits/confname.h \
    /usr/include/x86_64-linux-gnu/bits/cpu-set.h \
    /usr/include/x86_64-linux-gnu/bits/dirent.h \
    /usr/include/x86_64-linux-gnu/bits/dlfcn.h \
    /usr/include/x86_64-linux-gnu/bits/elfclass.h \
    /usr/include/x86_64-linux-gnu/bits/endian.h \
    /usr/include/x86_64-linux-gnu/bits/environments.h \
    /usr/include/x86_64-linux-gnu/bits/epoll.h \
    /usr/include/x86_64-linux-gnu/bits/errno.h \
    /usr/include/x86_64-linux-gnu/bits/eventfd.h \
    /usr/include/x86_64-linux-gnu/bits/fcntl-linux.h \
    /usr/include/x86_64-linux-gnu/bits/fcntl.h \
    /usr/include/x86_64-linux-gnu/bits/fcntl2.h \
    /usr/include/x86_64-linux-gnu/bits/fenv.h \
    /usr/include/x86_64-linux-gnu/bits/fenvinline.h \
    /usr/include/x86_64-linux-gnu/bits/floatn-common.h \
    /usr/include/x86_64-linux-gnu/bits/floatn.h \
    /usr/include/x86_64-linux-gnu/bits/flt-eval-method.h \
    /usr/include/x86_64-linux-gnu/bits/fp-fast.h \
    /usr/include/x86_64-linux-gnu/bits/fp-logb.h \
    /usr/include/x86_64-linux-gnu/bits/getopt_core.h \
    /usr/include/x86_64-linux-gnu/bits/getopt_ext.h \
    /usr/include/x86_64-linux-gnu/bits/getopt_posix.h \
    /usr/include/x86_64-linux-gnu/bits/hwcap.h \
    /usr/include/x86_64-linux-gnu/bits/in.h \
    /usr/include/x86_64-linux-gnu/bits/inotify.h \
    /usr/include/x86_64-linux-gnu/bits/ioctl-types.h \
    /usr/include/x86_64-linux-gnu/bits/ioctls.h \
    /usr/include/x86_64-linux-gnu/bits/ipc.h \
    /usr/include/x86_64-linux-gnu/bits/ipctypes.h \
    /usr/include/x86_64-linux-gnu/bits/iscanonical.h \
    /usr/include/x86_64-linux-gnu/bits/libc-header-start.h \
    /usr/include/x86_64-linux-gnu/bits/libio.h \
    /usr/include/x86_64-linux-gnu/bits/libm-simd-decl-stubs.h \
    /usr/include/x86_64-linux-gnu/bits/link.h \
    /usr/include/x86_64-linux-gnu/bits/local_lim.h \
    /usr/include/x86_64-linux-gnu/bits/locale.h \
    /usr/include/x86_64-linux-gnu/bits/long-double.h \
    /usr/include/x86_64-linux-gnu/bits/math-vector.h \
    /usr/include/x86_64-linux-gnu/bits/mathcalls-helper-functions.h \
    /usr/include/x86_64-linux-gnu/bits/mathcalls.h \
    /usr/include/x86_64-linux-gnu/bits/mathdef.h \
    /usr/include/x86_64-linux-gnu/bits/mathinline.h \
    /usr/include/x86_64-linux-gnu/bits/mman-linux.h \
    /usr/include/x86_64-linux-gnu/bits/mman-shared.h \
    /usr/include/x86_64-linux-gnu/bits/mman.h \
    /usr/include/x86_64-linux-gnu/bits/netdb.h \
    /usr/include/x86_64-linux-gnu/bits/param.h \
    /usr/include/x86_64-linux-gnu/bits/poll.h \
    /usr/include/x86_64-linux-gnu/bits/poll2.h \
    /usr/include/x86_64-linux-gnu/bits/posix1_lim.h \
    /usr/include/x86_64-linux-gnu/bits/posix2_lim.h \
    /usr/include/x86_64-linux-gnu/bits/posix_opt.h \
    /usr/include/x86_64-linux-gnu/bits/pthreadtypes-arch.h \
    /usr/include/x86_64-linux-gnu/bits/pthreadtypes.h \
    /usr/include/x86_64-linux-gnu/bits/ptrace-shared.h \
    /usr/include/x86_64-linux-gnu/bits/resource.h \
    /usr/include/x86_64-linux-gnu/bits/sched.h \
    /usr/include/x86_64-linux-gnu/bits/select.h \
    /usr/include/x86_64-linux-gnu/bits/select2.h \
    /usr/include/x86_64-linux-gnu/bits/sem.h \
    /usr/include/x86_64-linux-gnu/bits/semaphore.h \
    /usr/include/x86_64-linux-gnu/bits/setjmp.h \
    /usr/include/x86_64-linux-gnu/bits/setjmp2.h \
    /usr/include/x86_64-linux-gnu/bits/shm.h \
    /usr/include/x86_64-linux-gnu/bits/sigaction.h \
    /usr/include/x86_64-linux-gnu/bits/sigcontext.h \
    /usr/include/x86_64-linux-gnu/bits/sigevent-consts.h \
    /usr/include/x86_64-linux-gnu/bits/siginfo-arch.h \
    /usr/include/x86_64-linux-gnu/bits/siginfo-consts-arch.h \
    /usr/include/x86_64-linux-gnu/bits/siginfo-consts.h \
    /usr/include/x86_64-linux-gnu/bits/signum-generic.h \
    /usr/include/x86_64-linux-gnu/bits/signum.h \
    /usr/include/x86_64-linux-gnu/bits/sigstack.h \
    /usr/include/x86_64-linux-gnu/bits/sigthread.h \
    /usr/include/x86_64-linux-gnu/bits/sockaddr.h \
    /usr/include/x86_64-linux-gnu/bits/socket.h \
    /usr/include/x86_64-linux-gnu/bits/socket2.h \
    /usr/include/x86_64-linux-gnu/bits/socket_type.h \
    /usr/include/x86_64-linux-gnu/bits/ss_flags.h \
    /usr/include/x86_64-linux-gnu/bits/stab.def \
    /usr/include/x86_64-linux-gnu/bits/stat.h \
    /usr/include/x86_64-linux-gnu/bits/statfs.h \
    /usr/include/x86_64-linux-gnu/bits/statvfs.h \
    /usr/include/x86_64-linux-gnu/bits/stdint-intn.h \
    /usr/include/x86_64-linux-gnu/bits/stdint-uintn.h \
    /usr/include/x86_64-linux-gnu/bits/stdio.h \
    /usr/include/x86_64-linux-gnu/bits/stdio2.h \
    /usr/include/x86_64-linux-gnu/bits/stdio_lim.h \
    /usr/include/x86_64-linux-gnu/bits/stdlib-bsearch.h \
    /usr/include/x86_64-linux-gnu/bits/stdlib-float.h \
    /usr/include/x86_64-linux-gnu/bits/stdlib.h \
    /usr/include/x86_64-linux-gnu/bits/string_fortified.h \
    /usr/include/x86_64-linux-gnu/bits/strings_fortified.h \
    /usr/include/x86_64-linux-gnu/bits/stropts.h \
    /usr/include/x86_64-linux-gnu/bits/sys_errlist.h \
    /usr/include/x86_64-linux-gnu/bits/syscall.h \
    /usr/include/x86_64-linux-gnu/bits/syslog-path.h \
    /usr/include/x86_64-linux-gnu/bits/syslog.h \
    /usr/include/x86_64-linux-gnu/bits/sysmacros.h \
    /usr/include/x86_64-linux-gnu/bits/termios.h \
    /usr/include/x86_64-linux-gnu/bits/thread-shared-types.h \
    /usr/include/x86_64-linux-gnu/bits/time.h \
    /usr/include/x86_64-linux-gnu/bits/timerfd.h \
    /usr/include/x86_64-linux-gnu/bits/timex.h \
    /usr/include/x86_64-linux-gnu/bits/types/FILE.h \
    /usr/include/x86_64-linux-gnu/bits/types/__FILE.h \
    /usr/include/x86_64-linux-gnu/bits/types/__locale_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/__mbstate_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/__sigset_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/__sigval_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/clock_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/clockid_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/locale_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/mbstate_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/res_state.h \
    /usr/include/x86_64-linux-gnu/bits/types/sig_atomic_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/sigevent_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/siginfo_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/sigset_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/sigval_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/stack_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/struct_iovec.h \
    /usr/include/x86_64-linux-gnu/bits/types/struct_itimerspec.h \
    /usr/include/x86_64-linux-gnu/bits/types/struct_osockaddr.h \
    /usr/include/x86_64-linux-gnu/bits/types/struct_rusage.h \
    /usr/include/x86_64-linux-gnu/bits/types/struct_sigstack.h \
    /usr/include/x86_64-linux-gnu/bits/types/struct_timespec.h \
    /usr/include/x86_64-linux-gnu/bits/types/struct_timeval.h \
    /usr/include/x86_64-linux-gnu/bits/types/struct_tm.h \
    /usr/include/x86_64-linux-gnu/bits/types/time_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/timer_t.h \
    /usr/include/x86_64-linux-gnu/bits/types/wint_t.h \
    /usr/include/x86_64-linux-gnu/bits/types.h \
    /usr/include/x86_64-linux-gnu/bits/typesizes.h \
    /usr/include/x86_64-linux-gnu/bits/uintn-identity.h \
    /usr/include/x86_64-linux-gnu/bits/uio-ext.h \
    /usr/include/x86_64-linux-gnu/bits/uio_lim.h \
    /usr/include/x86_64-linux-gnu/bits/unistd.h \
    /usr/include/x86_64-linux-gnu/bits/utsname.h \
    /usr/include/x86_64-linux-gnu/bits/waitflags.h \
    /usr/include/x86_64-linux-gnu/bits/waitstatus.h \
    /usr/include/x86_64-linux-gnu/bits/wchar.h \
    /usr/include/x86_64-linux-gnu/bits/wchar2.h \
    /usr/include/x86_64-linux-gnu/bits/wctype-wchar.h \
    /usr/include/x86_64-linux-gnu/bits/wordsize.h \
    /usr/include/x86_64-linux-gnu/bits/xopen_lim.h \
    /usr/include/x86_64-linux-gnu/bits/xtitypes.h \
    /usr/include/x86_64-linux-gnu/fpu_control.h \
    /usr/include/x86_64-linux-gnu/gnu/libc-version.h \
    /usr/include/x86_64-linux-gnu/gnu/stubs-64.h \
    /usr/include/x86_64-linux-gnu/gnu/stubs.h \
    /usr/include/x86_64-linux-gnu/sys/auxv.h \
    /usr/include/x86_64-linux-gnu/sys/cdefs.h \
    /usr/include/x86_64-linux-gnu/sys/epoll.h \
    /usr/include/x86_64-linux-gnu/sys/errno.h \
    /usr/include/x86_64-linux-gnu/sys/eventfd.h \
    /usr/include/x86_64-linux-gnu/sys/fcntl.h \
    /usr/include/x86_64-linux-gnu/sys/file.h \
    /usr/include/x86_64-linux-gnu/sys/inotify.h \
    /usr/include/x86_64-linux-gnu/sys/ioctl.h \
    /usr/include/x86_64-linux-gnu/sys/ipc.h \
    /usr/include/x86_64-linux-gnu/sys/mman.h \
    /usr/include/x86_64-linux-gnu/sys/mount.h \
    /usr/include/x86_64-linux-gnu/sys/param.h \
    /usr/include/x86_64-linux-gnu/sys/poll.h \
    /usr/include/x86_64-linux-gnu/sys/prctl.h \
    /usr/include/x86_64-linux-gnu/sys/procfs.h \
    /usr/include/x86_64-linux-gnu/sys/ptrace.h \
    /usr/include/x86_64-linux-gnu/sys/random.h \
    /usr/include/x86_64-linux-gnu/sys/resource.h \
    /usr/include/x86_64-linux-gnu/sys/select.h \
    /usr/include/x86_64-linux-gnu/sys/sem.h \
    /usr/include/x86_64-linux-gnu/sys/sendfile.h \
    /usr/include/x86_64-linux-gnu/sys/shm.h \
    /usr/include/x86_64-linux-gnu/sys/signal.h \
    /usr/include/x86_64-linux-gnu/sys/socket.h \
    /usr/include/x86_64-linux-gnu/sys/stat.h \
    /usr/include/x86_64-linux-gnu/sys/statfs.h \
    /usr/include/x86_64-linux-gnu/sys/statvfs.h \
    /usr/include/x86_64-linux-gnu/sys/syscall.h \
    /usr/include/x86_64-linux-gnu/sys/sysinfo.h \
    /usr/include/x86_64-linux-gnu/sys/syslog.h \
    /usr/include/x86_64-linux-gnu/sys/sysmacros.h \
    /usr/include/x86_64-linux-gnu/sys/time.h \
    /usr/include/x86_64-linux-gnu/sys/timerfd.h \
    /usr/include/x86_64-linux-gnu/sys/times.h \
    /usr/include/x86_64-linux-gnu/sys/ttydefaults.h \
    /usr/include/x86_64-linux-gnu/sys/types.h \
    /usr/include/x86_64-linux-gnu/sys/ucontext.h \
    /usr/include/x86_64-linux-gnu/sys/uio.h \
    /usr/include/x86_64-linux-gnu/sys/un.h \
    /usr/include/x86_64-linux-gnu/sys/user.h \
    /usr/include/x86_64-linux-gnu/sys/utsname.h \
    /usr/include/x86_64-linux-gnu/sys/vfs.h \
    /usr/include/x86_64-linux-gnu/sys/wait.h \
    toolchain

# Additional packages
cp -r --parents \
    /usr/include/zlib.h \
    /usr/include/zconf.h \
    /usr/include/openssl \
    /usr/include/x86_64-linux-gnu/openssl \
    toolchain

# compiler-rt
cp -r --parents \
    /usr/include/crypt.h \
    /usr/include/fstab.h \
    /usr/include/mqueue.h \
    /usr/include/net/if_ppp.h \
    /usr/include/net/route.h \
    /usr/include/netax25/ax25.h \
    /usr/include/netinet/ether.h \
    /usr/include/net/ppp_defs.h \
    /usr/include/netinet/if_ether.h \
    /usr/include/netipx/ipx.h \
    /usr/include/netrom/netrom.h \
    /usr/include/obstack.h \
    /usr/include/scsi/scsi.h \
    /usr/include/utmp.h \
    /usr/include/utmpx.h \
    /usr/include/x86_64-linux-gnu/bits/mqueue.h \
    /usr/include/x86_64-linux-gnu/bits/mqueue2.h \
    /usr/include/x86_64-linux-gnu/bits/msq.h \
    /usr/include/x86_64-linux-gnu/bits/utmp.h \
    /usr/include/x86_64-linux-gnu/bits/utmpx.h \
    /usr/include/x86_64-linux-gnu/sys/kd.h \
    /usr/include/x86_64-linux-gnu/sys/msg.h \
    /usr/include/x86_64-linux-gnu/sys/mtio.h \
    /usr/include/x86_64-linux-gnu/sys/personality.h \
    /usr/include/x86_64-linux-gnu/sys/timeb.h \
    /usr/include/x86_64-linux-gnu/sys/timex.h \
    /usr/include/x86_64-linux-gnu/sys/vt.h \
    toolchain

# Python-3.6.6
cp -r --parents \
    /usr/include/rpc \
    /usr/include/rpcsvc \
    /usr/include/x86_64-linux-gnu/sys/soundcard.h \
    toolchain

# Additional libs
cp -L \
    /usr/lib/x86_64-linux-gnu/libiberty.a \
    /usr/lib/x86_64-linux-gnu/libz.a \
    /usr/lib/x86_64-linux-gnu/libbfd.a \
    /usr/lib/x86_64-linux-gnu/libcrypt.a \
    /usr/lib/x86_64-linux-gnu/libtinfo.a \
    /usr/lib/x86_64-linux-gnu/libtic.a \
    /usr/lib/x86_64-linux-gnu/libtermcap.a \
    /usr/lib/x86_64-linux-gnu/libssl.a \
    /usr/lib/x86_64-linux-gnu/libcrypto.a \
    /usr/lib/x86_64-linux-gnu/libnsl.a \
    toolchain/usr/lib/

# Additional libs usually don't provide stable abi.
# Let's also force static link
# TODO header files are incomplete. Also cmake might still find system libs instead
# for lib in libz libbfd libcrypt libtinfo libtic libssl libcrypto libnsl; do
#     echo "OUTPUT_FORMAT(elf64-x86-64)
# GROUP ( ./$lib.a )
# " >toolchain/usr/lib/$lib.so
# done
# TODO ubuntu static libs are mostly compiled without -fPIC. Have to use .so for now.
# TODO Will it break anything? Perhaps we should only provide .a files
for lib in libz libbfd libcrypt libtinfo libtic libtermcap libssl libcrypto libnsl; do
    cp -L /usr/lib/x86_64-linux-gnu/$lib.so toolchain/usr/lib/$lib.so
done

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( ./libglibc-compatibility.a ../../lib/libc.so.6 ./libc_nonshared.a  AS_NEEDED ( ../../lib/ld-linux-x86-64.so.2 ) )
" >toolchain/usr/lib/libc.so

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( ../../lib/libpthread.so.0 ./libpthread_nonshared.a )
" >toolchain/usr/lib/libpthread.so

ln -s ../../lib/libdl.so.2 toolchain/usr/lib/libdl.so

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( ./libglibc-compatibility.a ../../lib/libm.so.6 )
" >toolchain/usr/lib/libm.so

ln -s ../../lib/libresolv.so.2 toolchain/usr/lib/libresolv.so
ln -s ../../lib/librt.so.1 toolchain/usr/lib/librt.so

cp -L /usr/lib/x86_64-linux-gnu/crt1.o toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/crti.o toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/crtn.o toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/libc_nonshared.a toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/libpthread_nonshared.a toolchain/usr/lib/

cp -L /usr/lib/x86_64-linux-gnu/Mcrt1.o toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/Scrt1.o toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/gcrt1.o toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/grcrt1.o toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/rcrt1.o toolchain/usr/lib/

# static build
cp -L /usr/lib/x86_64-linux-gnu/libc.a toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/libpthread.a toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/libdl.a toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/librt.a toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/libresolv.a toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/libffi.a toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/libffi_pic.a toolchain/usr/lib/

echo "/* GNU ld script
*/
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( ./libglibc-compatibility.a ./libm-2.27.a ./libmvec.a )
" >toolchain/usr/lib/libm.a
cp -L /usr/lib/x86_64-linux-gnu/libm-2.27.a toolchain/usr/lib/
cp -L /usr/lib/x86_64-linux-gnu/libmvec.a toolchain/usr/lib/

# We provide bison wrapper to make sure it picks up our m4 and pkg data
mv toolchain/bin/bison toolchain/bin/bison-3.5.1

cp -r /wrappers/* toolchain/bin/

# Setup gcc toolchains

mkdir -p toolchain/lib/gcc/x86_64-linux-gnu/11

for f in /opt/exodus/bundles/*/usr/lib/gcc/x86_64-linux-gnu/11/*-x
do
    p=$(basename $f)
    g=${p::-2}
    cp -L $f toolchain/lib/gcc/x86_64-linux-gnu/11/$g
    ./patchelf --set-interpreter "$PWD/toolchain/lib/ld-linux-x86-64.so.2" --set-rpath '$ORIGIN/../../..' toolchain/lib/gcc/x86_64-linux-gnu/11/$g
done

cp -r -L /usr/lib/gcc/x86_64-linux-gnu/11/crtbegin.o \
         /usr/lib/gcc/x86_64-linux-gnu/11/crtend.o \
         /usr/lib/gcc/x86_64-linux-gnu/11/crtbeginT.o \
         /usr/lib/gcc/x86_64-linux-gnu/11/crtbeginS.o \
         /usr/lib/gcc/x86_64-linux-gnu/11/crtendS.o \
         /usr/lib/gcc/x86_64-linux-gnu/11/libgcc_eh.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/libgcc.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/libstdc++.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/libstdc++fs.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/libatomic.so \
         /usr/lib/gcc/x86_64-linux-gnu/11/libatomic.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/liblto_plugin.so \
         /usr/lib/gcc/x86_64-linux-gnu/11/libgcov.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/libsanitizer.spec \
         /usr/lib/gcc/x86_64-linux-gnu/11/libasan_preinit.o \
         /usr/lib/gcc/x86_64-linux-gnu/11/libasan.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/libasan.so \
         /usr/lib/gcc/x86_64-linux-gnu/11/libtsan.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/libtsan.so \
         /usr/lib/gcc/x86_64-linux-gnu/11/libubsan.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/libubsan.so \
         /usr/lib/gcc/x86_64-linux-gnu/11/liblsan_preinit.o \
         /usr/lib/gcc/x86_64-linux-gnu/11/liblsan.a \
         /usr/lib/gcc/x86_64-linux-gnu/11/liblsan.so \
         /usr/lib/gcc/x86_64-linux-gnu/11/include \
    toolchain/lib/gcc/x86_64-linux-gnu/11

# gomp
cp -r -L \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtfastmath.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtoffloadbegin.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtoffloadend.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtoffloadtable.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtprec32.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtprec64.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtprec80.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/libgomp.a \
    /usr/lib/gcc/x86_64-linux-gnu/11/libgomp.so \
    /usr/lib/gcc/x86_64-linux-gnu/11/libgomp.spec \
    toolchain/lib/gcc/x86_64-linux-gnu/11

for so in toolchain/lib/gcc/x86_64-linux-gnu/11/*.so
do
    ./patchelf --set-rpath '$ORIGIN/../../..' "$so"
done

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( ./libstdc++.a ./libstdc++fs.a )
" >toolchain/lib/gcc/x86_64-linux-gnu/11/libstdc++.so

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( ../../../libgcc_s.so.1 -lgcc )
" >toolchain/lib/gcc/x86_64-linux-gnu/11/libgcc_s.so

# Sometimes static linking might still link to libgcc_s. Use ld script to redirect.
echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( -lgcc )
" >toolchain/lib/gcc/x86_64-linux-gnu/11/libgcc_s.a

mkdir -p toolchain/include/x86_64-linux-gnu/c++
mkdir -p toolchain/include/c++

cp -r /usr/include/x86_64-linux-gnu/c++/11 toolchain/include/x86_64-linux-gnu/c++/
cp -r /usr/include/c++/11 toolchain/include/c++/

# Setup clang toolchains

mkdir -p toolchain/lib/clang

cp -r -L /usr/lib/clang/${LLVM_VERSION} toolchain/lib/clang/${LLVM_VERSION_FULL}

for so in toolchain/lib/clang/${LLVM_VERSION_FULL}/lib/linux/*.so
do
    ./patchelf --set-rpath '$ORIGIN/../../../..' "$so"
done

# libc++

cp -r /usr/lib/llvm-${LLVM_VERSION}/include/c++/v1 toolchain/include/c++/

cp -L \
        /usr/lib/llvm-${LLVM_VERSION}/lib/libunwind.so \
        /usr/lib/llvm-${LLVM_VERSION}/lib/libc++abi.so \
        /usr/lib/llvm-${LLVM_VERSION}/lib/libc++.so.1 \
        /usr/lib/llvm-${LLVM_VERSION}/lib/libunwind.a \
        /usr/lib/llvm-${LLVM_VERSION}/lib/libc++.a \
        /usr/lib/llvm-${LLVM_VERSION}/lib/libc++experimental.a \
        /usr/lib/llvm-${LLVM_VERSION}/lib/libc++abi.a \
    toolchain/lib/

./patchelf --set-rpath '$ORIGIN' toolchain/lib/libc++.so.1
./patchelf --set-rpath '$ORIGIN' toolchain/lib/libc++abi.so
./patchelf --set-rpath '$ORIGIN' toolchain/lib/libunwind.so
echo "INPUT(./libc++.so.1 -lunwind -lc++abi)" >toolchain/lib/libc++.so

# For cmake file DOWNLOAD support
./patchelf --add-needed libnss_files.so.2 --add-needed libnss_dns.so.2 toolchain/bin/cmake

cp ./patchelf toolchain/bin/
cp -r /tests toolchain/test

mv toolchain/bin/python3 toolchain/bin/ldb-python3
cp -r /usr/lib/python3.6 toolchain/lib/
cp -r /usr/share/gdb toolchain/share/
mkdir -p toolchain/share/gdb/libcxx
cp /opt/printers.py toolchain/share/gdb/libcxx/

cp /usr/bin/gdb-add-index toolchain/bin/
cp /usr/bin/google-pprof toolchain/bin/pprof

cp -r /usr/share/bison toolchain/share/
cp -r /usr/share/aclocal toolchain/share/

(
    cd /glibc-compatibility
    mkdir -p build
    cd build
    /data/toolchain/bin/cmake -DCMAKE_C_COMPILER=/usr/lib/llvm-${LLVM_VERSION}/bin/clang -DCMAKE_CXX_COMPILER=/usr/lib/llvm-${LLVM_VERSION}/bin/clang++ ..
    make
) &> /dev/null

cp /glibc-compatibility/build/libglibc-compatibility.a toolchain/usr/lib/

tar czf toolchain.tgz toolchain

cat /setup_toolchain.sh toolchain.tgz > ldb_toolchain_gen.sh

chmod +x ldb_toolchain_gen.sh
