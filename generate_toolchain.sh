#!/usr/bin/env bash

set -x
# Generate toolchain.tgz in CWD

set -e

if [[ -e "toolchain" ]]; then
    echo "Dir toolchain/ already exists"
    exit 1
fi

mkdir -p toolchain/{bin,lib,libexec}

# GCC finds either ${ARCH}-unknown-linux-gnu/${GCC_VERSION} or ${ARCH}-linux-gnu/
mkdir -p toolchain/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}

binaries=(
    /usr/bin/yasm
    /usr/bin/nm
    /usr/bin/addr2line
    /usr/bin/curl
    /usr/bin/m4
    /usr/bin/bison
    /usr/bin/flex
    /usr/bin/pkg-config
    /tmp/gentoo/usr/bin/python
    /tmp/gentoo/usr/bin/nasm
    /tmp/gentoo/usr/bin/gdb
    /tmp/gentoo/usr/bin/ninja
    /tmp/gentoo/usr/bin/as
    /tmp/gentoo/usr/bin/ld.bfd
    /tmp/gentoo/usr/bin/gcc-ranlib
    /tmp/gentoo/usr/bin/gcc-ar
    /tmp/gentoo/usr/bin/gcc-nm
    /tmp/gentoo/usr/bin/${ARCH}-unknown-linux-gnu-cpp
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/clang-tidy
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/clang-format
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/clang-cpp
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-link
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llc
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/opt
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/clang-scan-deps
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-addr2line
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-strip
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-install-name-tool
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-objcopy
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-ranlib
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-ar
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-nm
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-cov
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-profdata
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-profgen
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/llvm-symbolizer
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/lld
    /tmp/gentoo/usr/bin/lldb-argdumper
    /tmp/gentoo/usr/bin/lldb-instr
    /tmp/gentoo/usr/bin/lldb-server
    /tmp/gentoo/usr/bin/lldb-dap
    /tmp/gentoo/usr/bin/lldb
)

for bin in "${binaries[@]}"; do
    cp "$bin" toolchain/bin/
done

mkdir -p toolchain/tmp/gentoo/bin

gcc_drivers=(
    /tmp/gentoo/usr/bin/g++
    /tmp/gentoo/usr/bin/gcc
)

for bin in "${gcc_drivers[@]}"; do
    cp "$bin" toolchain/tmp/gentoo/bin/
done

mkdir -p toolchain/tmp/gentoo/llvm/bin

clang_drivers=(
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/clang
    /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/clangd
)

for bin in "${clang_drivers[@]}"; do
    cp "$bin" toolchain/tmp/gentoo/llvm/bin/
done

gcc_binaries=(
    /tmp/gentoo/usr/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/lto1
    /tmp/gentoo/usr/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/lto-wrapper
    /tmp/gentoo/usr/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/cc1
    /tmp/gentoo/usr/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/cc1plus
    /tmp/gentoo/usr/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/collect2
    /tmp/gentoo/usr/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/g++-mapper-server
)

for bin in "${gcc_binaries[@]}"; do
    objcopy --strip-debug --remove-section=.comment --remove-section=.note \
        "$bin" "toolchain/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/$(basename $bin)"
done

while read -r lib
do
    cp "$lib" toolchain/lib/
done < <(./ldd-recursive.pl "${binaries[@]}" "${gcc_drivers[@]}" "${clang_drivers[@]}" "${gcc_binaries[@]}")

cp -L \
    /lib/${ARCH}-linux-gnu/libresolv.so.2 \
    /lib/${ARCH}-linux-gnu/libnss_nisplus.so.2 \
    /lib/${ARCH}-linux-gnu/libnss_compat.so.2 \
    /lib/${ARCH}-linux-gnu/libnss_dns.so.2 \
    /lib/${ARCH}-linux-gnu/libnss_files.so.2 \
    /lib/${ARCH}-linux-gnu/libnss_hesiod.so.2 \
    /lib/${ARCH}-linux-gnu/libnss_nis.so.2 \
    /lib/${ARCH}-linux-gnu/libtinfo.so.5 \
    /lib/${ARCH}-linux-gnu/libncursesw.so.5 \
    toolchain/lib/

# Provide gperf CPU profiler
cp -L /usr/lib/${ARCH}-linux-gnu/libprofiler.so.0.4.8 toolchain/lib/libprofiler.so
cp -L /usr/lib/${ARCH}-linux-gnu/libunwind.so.8 toolchain/lib/

gcc -shared -fPIC /disable_ld_preload.c -o toolchain/lib/disable_ld_preload.so -ldl

tar xzf /opt/patchelf-0.14.3-${ARCH}.tar.gz ./bin/patchelf --strip-components=2

for lib in toolchain/lib/*; do
    name=$(basename "$lib")
    if [[ "$name" != "libc.so.6" && "$name" != ld-linux-* ]]; then
        ./patchelf --set-rpath '$ORIGIN' "$lib"
    fi
done

interpreter=""
if [ "${ARCH}" = "x86_64" ]; then
    interpreter="$PWD/toolchain/lib/ld-linux-x86-64.so.2"
elif [ "${ARCH}" = "aarch64" ]; then
    interpreter="$PWD/toolchain/lib/ld-linux-aarch64.so.1"
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

ln -sf ld.lld toolchain/bin/ld

if [ "${ARCH}" = "x86_64" ]; then
    ln -sf ld.lld toolchain/bin/x86_64-unknown-linux-gnu-ld # clang tries to find this linker
elif [ "${ARCH}" = "aarch64" ]; then
    ln -sf ld.lld toolchain/bin/aarch64-linux-gnu-ld # clang tries to find this linker
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

cp /usr/bin/yacc toolchain/bin/

ln -sf lld toolchain/bin/ld.lld
ln -sf clang toolchain/tmp/gentoo/llvm/bin/clang++
ln -sf llvm-objcopy toolchain/bin/llvm-install-name-tool
ln -sf llvm-objcopy toolchain/bin/objcopy
ln -sf llvm-objdump toolchain/bin/objdump
ln -sf clang-cpp toolchain/bin/cpp
ln -sf llvm-ar toolchain/bin/ar
ln -sf llvm-ranlib toolchain/bin/ranlib
# llvm-nm somehow doesn't work when compiling hyperscan's fat runtime
# ln -sf llvm-nm-${LLVM_VERSION} toolchain/bin/nm
ln -sf gcc toolchain/bin/cc
ln -sf g++ toolchain/bin/c++

# ln -sf gcc-ranlib-11 toolchain/bin/ranlib
# ln -sf gcc-ar-11 toolchain/bin/ar
# ln -sf gcc-nm-11 toolchain/bin/nm

# gcc-ar-11
# gcc-nm-11
# gcc-ranlib-11

tar xzf /opt/cmake-3.29.0-linux-${ARCH}.tar.gz --strip-components=1 --exclude='*/doc' --exclude='*/man' -C toolchain

cp /FindThrift.cmake toolchain/share/cmake-3.29/Modules/

# JDK and Maven are too large
# mkdir toolchain/apache-maven-3.8.4
# tar xzf /opt/apache-maven-3.8.4-bin.tar.gz --strip-components=1 -C toolchain/apache-maven-3.8.4

# mkdir toolchain/openjdk-11.0.2
# tar xzf /opt/openjdk-11.0.2_linux-x64_bin.tar.gz --strip-components=1 -C toolchain/openjdk-11.0.2

# Setup sysroot

mkdir -p toolchain/usr/lib

cp -r --parents /usr/include toolchain

# Python
cp -r --parents \
    /usr/include/rpc \
    /usr/include/rpcsvc \
    /usr/include/${ARCH}-linux-gnu/sys/soundcard.h \
    toolchain

# fdb client
if [ "${ARCH}" = "x86_64" ]; then
    mkdir -p toolchain/fdb/lib toolchain/fdb/include
    cp -r /usr/include/foundationdb toolchain/fdb/include/

    # Require glibc >= 2.17
    cp /usr/lib/libfdb_c.so toolchain/fdb/lib/

    cp /usr/lib/cmake/FoundationDB-Client/* toolchain/
    sed -i 's=${_IMPORT_PREFIX}/usr/lib/libfdb_c.so=${CMAKE_CURRENT_LIST_DIR}/fdb/lib/libfdb_c.so=' \
        toolchain/FoundationDB-Client-release.cmake
    sed -i '/set_target_properties(fdb_c PROPERTIES/a\ \ INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/fdb/include"' \
        toolchain/FoundationDB-Client-release.cmake
fi

# Additional libs
cp -L \
    /usr/lib/${ARCH}-linux-gnu/libiberty.a \
    /usr/lib/${ARCH}-linux-gnu/libz.a \
    /usr/lib/${ARCH}-linux-gnu/libbfd.a \
    /usr/lib/${ARCH}-linux-gnu/libcrypt.a \
    /usr/lib/${ARCH}-linux-gnu/libtinfo.a \
    /usr/lib/${ARCH}-linux-gnu/libtic.a \
    /usr/lib/${ARCH}-linux-gnu/libtermcap.a \
    /usr/lib/${ARCH}-linux-gnu/libssl.a \
    /usr/lib/${ARCH}-linux-gnu/libcrypto.a \
    /usr/lib/${ARCH}-linux-gnu/libnsl.a \
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
    cp -L /usr/lib/${ARCH}-linux-gnu/$lib.so toolchain/usr/lib/$lib.so
done

output_format=""

if [ "${ARCH}" = "x86_64" ]; then
    output_format="x86-64"
elif [ "${ARCH}" = "aarch64" ]; then
    output_format="littleaarch64"
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

if [ "${ARCH}" = "x86_64" ]; then
    echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-${output_format})
GROUP ( ./libglibc-compatibility.a ../../lib/libc.so.6 ./libc_nonshared.a AS_NEEDED ( ../../lib/ld-linux-x86-64.so.2 ) )
" >toolchain/usr/lib/libc.so
elif [ "${ARCH}" = "aarch64" ]; then
    echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-${output_format})
GROUP ( ./libglibc-compatibility.a ../../lib/libc.so.6 ./libc_nonshared.a AS_NEEDED ( ../../lib/ld-linux-aarch64.so.1 ) )
" >toolchain/usr/lib/libc.so
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-${output_format})
GROUP ( ../../lib/libpthread.so.0 ./libpthread_nonshared.a )
" >toolchain/usr/lib/libpthread.so

ln -s ../../lib/libdl.so.2 toolchain/usr/lib/libdl.so

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-${output_format})
GROUP ( ./libglibc-compatibility.a ../../lib/libm.so.6 )
" >toolchain/usr/lib/libm.so

ln -s ../../lib/libresolv.so.2 toolchain/usr/lib/libresolv.so
ln -s ../../lib/librt.so.1 toolchain/usr/lib/librt.so

cp -L /usr/lib/${ARCH}-linux-gnu/crt1.o toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/crti.o toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/crtn.o toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libc_nonshared.a toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libpthread_nonshared.a toolchain/usr/lib/

cp -L /usr/lib/${ARCH}-linux-gnu/Mcrt1.o toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/Scrt1.o toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/gcrt1.o toolchain/usr/lib/

if [ "${ARCH}" = "x86_64" ]; then
    cp -L /usr/lib/${ARCH}-linux-gnu/grcrt1.o toolchain/usr/lib/
    cp -L /usr/lib/${ARCH}-linux-gnu/rcrt1.o toolchain/usr/lib/
fi

# rust build requires this
cp -L /usr/lib/${ARCH}-linux-gnu/libutil.so toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libutil.a toolchain/usr/lib/

# static build
cp -L /usr/lib/${ARCH}-linux-gnu/libc.a toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libpthread.a toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libdl.a toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/librt.a toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libresolv.a toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libffi.a toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libffi_pic.a toolchain/usr/lib/

if [ "${ARCH}" = "x86_64" ]; then
    echo "/* GNU ld script
*/
OUTPUT_FORMAT(elf64-${output_format})
GROUP ( ./libglibc-compatibility.a ./libm-2.27.a ./libmvec.a ./libpthread.a )
" >toolchain/usr/lib/libm.a
    cp -L /usr/lib/${ARCH}-linux-gnu/libm-2.27.a toolchain/usr/lib/
    cp -L /usr/lib/${ARCH}-linux-gnu/libmvec.a toolchain/usr/lib/
elif [ "${ARCH}" = "aarch64" ]; then
    echo "/* GNU ld script
*/
OUTPUT_FORMAT(elf64-${output_format})
GROUP ( ./libglibc-compatibility.a ./libm-2.27.a ./libpthread.a )
" >toolchain/usr/lib/libm.a
    cp -L /usr/lib/${ARCH}-linux-gnu/libm.a toolchain/usr/lib/libm-2.27.a
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

# We provide bison wrapper to make sure it picks up our m4 and pkg data
mv toolchain/bin/bison toolchain/bin/bison-3.5.1

# We provide curl wrapper to make sure curl can load runtime DSO from our lib
mv toolchain/bin/curl toolchain/bin/ldb-curl

cp -r /wrappers/* toolchain/bin/

sed -i "s:<ARCH>/<GCC_VERSION>:${ARCH}-unknown-linux-gnu/${GCC_VERSION}:" toolchain/bin/clang
sed -i "s:<ARCH>/<GCC_VERSION>:${ARCH}-unknown-linux-gnu/${GCC_VERSION}:" toolchain/bin/clang++

# Setup gcc toolchains

mkdir -p toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}

cp -r -L /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/crtbegin.o \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/crtend.o \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/crtbeginT.o \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/crtbeginS.o \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/crtendS.o \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgcc_eh.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgcc.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libstdc++.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libstdc++fs.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libatomic.so \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libatomic.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgcov.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libsanitizer.spec \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libasan_preinit.o \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libasan.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libasan.so \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libtsan.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libtsan.so \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libubsan.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libubsan.so \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/liblsan_preinit.o \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/liblsan.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/liblsan.so \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/include \
    toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}

cp -r -L /tmp/gentoo/usr/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/liblto_plugin.so toolchain/libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}

# gomp
cp -r -L \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/crtfastmath.o \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgomp.a \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgomp.so \
    /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgomp.spec \
    toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}

# libomp
cp -r -L \
    /tmp/gentoo/usr/include/omp.h \
    /tmp/gentoo/usr/include/ompx.h \
    toolchain/usr/include/

cp -r -L \
    /tmp/gentoo/usr/lib/libomp.a \
    toolchain/lib/libomp-bin.a

# newer clang doesn't work well with old glibc, missing dl when compiling with -fopenmp
echo "GROUP ( ./libomp-bin.a -ldl )" >toolchain/lib/libomp.a

ln -s gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgomp.so toolchain/lib/libgomp.so.1

if [ "${ARCH}" = "x86_64" ]; then
    cp -r -L \
        /tmp/gentoo/usr/lib/gcc/x86_64-unknown-linux-gnu/${GCC_VERSION}/crtprec32.o \
        /tmp/gentoo/usr/lib/gcc/x86_64-unknown-linux-gnu/${GCC_VERSION}/crtprec64.o \
        /tmp/gentoo/usr/lib/gcc/x86_64-unknown-linux-gnu/${GCC_VERSION}/crtprec80.o \
        toolchain/lib/gcc/x86_64-unknown-linux-gnu/${GCC_VERSION}
fi

for so in toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/*.so; do
    ./patchelf --set-rpath '$ORIGIN/../../..' "$so"
done

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( ./libstdc++.a ./libstdc++fs.a )
" >toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libstdc++.so

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( -lgcc -lgcc_eh )
" >toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgcc_s.so

# Sometimes static linking might still link to libgcc_s. Use ld script to redirect.
echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( -lgcc -lgcc_eh )
" >toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/libgcc_s.a

cp -r /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/include toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/
cp -r /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/include-fixed toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/
cp -r /tmp/gentoo/usr/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/finclude toolchain/lib/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/

# Setup clang resource includes

mkdir -p toolchain/lib/clang
cp -r -L /tmp/gentoo/usr/lib/clang/${LLVM_VERSION} toolchain/lib/clang/

# libc++

mkdir -p toolchain/include/c++
cp -r /tmp/gentoo/usr/include/c++/v1 toolchain/include/c++/

cp -L \
    /tmp/gentoo/usr/lib/libunwind.so \
    /tmp/gentoo/usr/lib/libc++.so.1 \
    /tmp/gentoo/usr/lib/libc++.a \
    /tmp/gentoo/usr/lib/libc++experimental.a \
    /tmp/gentoo/usr/lib/libc++_static.a \
    /tmp/gentoo/usr/lib/libc++abi.a \
    /tmp/gentoo/usr/lib/libc++abi.so \
    toolchain/lib/

./patchelf --set-rpath '$ORIGIN' toolchain/lib/libc++.so.1
./patchelf --set-rpath '$ORIGIN' toolchain/lib/libc++abi.so
./patchelf --set-rpath '$ORIGIN' toolchain/lib/libunwind.so
echo "INPUT(./libc++.so.1 -lunwind -lc++abi)" >toolchain/lib/libc++.so

# For cmake file DOWNLOAD support
./patchelf --add-needed libnss_files.so.2 --add-needed libnss_dns.so.2 toolchain/bin/cmake

cp ./patchelf toolchain/bin/
cp -r /tests toolchain/test

mv toolchain/bin/python toolchain/bin/ldb-python
cp -r /tmp/gentoo/usr/lib/python3.12 toolchain/lib/
cp -r /tmp/gentoo/usr/share/gdb toolchain/share/
# printers for gcc
# cp -r /tmp/gentoo/usr/share/gcc toolchain/share/gdb/
# printers for clang
mkdir -p toolchain/share/gdb/libcxx
cp /opt/printers.py toolchain/share/gdb/libcxx/

cp /tmp/gentoo/usr/bin/gdb-add-index toolchain/bin/
cp /usr/bin/google-pprof toolchain/bin/pprof

cp -r /usr/share/bison toolchain/share/
cp -r /usr/share/aclocal toolchain/share/

ln -s lib toolchain/lib64

(
    cd /glibc-compatibility
    mkdir -p build
    cd build
    /data/toolchain/bin/cmake ..
    make
    /data/toolchain/bin/ar x libglibc-compatibility.a
    /data/toolchain/bin/ld -relocatable ./*.o -o glibc-compatibility.o
)

cp /glibc-compatibility/build/libglibc-compatibility.a /glibc-compatibility/build/glibc-compatibility.o toolchain/usr/lib/

tar czf toolchain.tgz toolchain

sed -i "s/\${ARCH}/$ARCH/g" /setup_toolchain.sh
sed -i "s/\${GCC_VERSION}/$GCC_VERSION/g" /setup_toolchain.sh
sed -i "s/\${LLVM_VERSION}/$LLVM_VERSION/g" /setup_toolchain.sh

cat /setup_toolchain.sh toolchain.tgz >ldb_toolchain_gen.sh

chmod +x ldb_toolchain_gen.sh
