#!/usr/bin/env bash

# Generate toolchain.tgz in CWD

set -e

if [[ -e "toolchain" ]]; then
    echo "Dir toolchain/ already exists"
    exit 1
fi

mkdir -p toolchain/{bin,lib}

cp -r -L /opt/exodus/bundles/*/lib/${ARCH}-linux-gnu/* toolchain/lib/

cp -r -L /opt/exodus/bundles/*/usr/lib/${ARCH}-linux-gnu/* toolchain/lib/

cp -r -L /opt/exodus/bundles/*/usr/lib/*.so* toolchain/lib/

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
if [ "${ARCH}" = "x86_64" ]; then
    cp -L /usr/lib/${ARCH}-linux-gnu/libunwind.so.8 toolchain/lib/
elif [ "${ARCH}" = "aarch64" ]; then
    cp -L /usr/lib/${ARCH}-linux-gnu/libunwind.so.1 toolchain/lib/
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

gcc -shared -fPIC /disable_ld_preload.c -o toolchain/lib/disable_ld_preload.so -ldl

tar xzf /opt/patchelf-0.14.3-${ARCH}.tar.gz ./bin/patchelf --strip-components=2

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

interpreter=""
if [ "${ARCH}" = "x86_64" ]; then
    interpreter="$PWD/toolchain/lib/ld-linux-x86-64.so.2"
elif [ "${ARCH}" = "aarch64" ]; then
    interpreter="$PWD/toolchain/lib/ld-linux-aarch64.so.1"
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

for bin in toolchain/bin/*; do
    ./patchelf --set-interpreter "$interpreter" --set-rpath '$ORIGIN/../lib' "$bin"
done

ln -sf ld.bfd toolchain/bin/ld

if [ "${ARCH}" = "x86_64" ]; then
    ln -sf ld.bfd toolchain/bin/x86_64-pc-linux-gnu-ld # clang tries to find this linker
elif [ "${ARCH}" = "aarch64" ]; then
    ln -sf ld.bfd toolchain/bin/aarch64-linux-gnu-ld # clang tries to find this linker
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

ln -sf lld-${LLVM_VERSION} toolchain/bin/ld.lld
ln -sf lld-${LLVM_VERSION} toolchain/bin/ld.lld-${LLVM_VERSION}
ln -sf clang-${LLVM_VERSION} toolchain/bin/clang++-${LLVM_VERSION}
ln -sf llvm-objcopy-${LLVM_VERSION} toolchain/bin/objcopy
ln -sf llvm-objdump-${LLVM_VERSION} toolchain/bin/objdump
ln -sf clang-cpp-${LLVM_VERSION} toolchain/bin/cpp
ln -sf llvm-ar-${LLVM_VERSION} toolchain/bin/ar
ln -sf llvm-ranlib-${LLVM_VERSION} toolchain/bin/ranlib
# llvm-nm somehow doesn't work when compiling hyperscan's fat runtime
# ln -sf llvm-nm-${LLVM_VERSION} toolchain/bin/nm
ln -sf lldb-${LLVM_VERSION} toolchain/bin/lldb
ln -sf clangd-${LLVM_VERSION} toolchain/bin/clangd
ln -sf clang-tidy-${LLVM_VERSION} toolchain/bin/clang-tidy
ln -sf clang-format-${LLVM_VERSION} toolchain/bin/clang-format
ln -sf gcc toolchain/bin/cc
ln -sf g++ toolchain/bin/c++
mv toolchain/bin/lldb-server-${LLVM_VERSION} toolchain/bin/lldb-server-${LLVM_VERSION}.0.1

# ln -sf gcc-ranlib-11 toolchain/bin/ranlib
# ln -sf gcc-ar-11 toolchain/bin/ar
# ln -sf gcc-nm-11 toolchain/bin/nm

# gcc-ar-11
# gcc-nm-11
# gcc-ranlib-11

if [ "${ARCH}" = "x86_64" ]; then
    cp -L /opt/exodus/bundles/*/usr/bin/linker-* toolchain/lib/ld-linux-x86-64.so.2
elif [ "${ARCH}" = "aarch64" ]; then
    cp -L /opt/exodus/bundles/*/usr/bin/linker-* toolchain/lib/ld-linux-aarch64.so.1
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi

tar xzf /opt/cmake-3.22.1-linux-${ARCH}.tar.gz --strip-components=1 --exclude='*/doc' --exclude='*/man' -C toolchain

# JDK and Maven are too large
# mkdir toolchain/apache-maven-3.8.4
# tar xzf /opt/apache-maven-3.8.4-bin.tar.gz --strip-components=1 -C toolchain/apache-maven-3.8.4

# mkdir toolchain/openjdk-11.0.2
# tar xzf /opt/openjdk-11.0.2_linux-x64_bin.tar.gz --strip-components=1 -C toolchain/openjdk-11.0.2

# Setup sysroot

mkdir -p toolchain/usr/lib

cp -r --parents /usr/include toolchain

# Python-3.6.6
cp -r --parents \
    /usr/include/rpc \
    /usr/include/rpcsvc \
    /usr/include/${ARCH}-linux-gnu/sys/soundcard.h \
    toolchain

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
GROUP ( ./libglibc-compatibility.a ../../lib/libc.so.6 ./libc_nonshared.a  AS_NEEDED ( ../../lib/ld-linux-x86-64.so.2 ) )
" >toolchain/usr/lib/libc.so
elif [ "${ARCH}" = "aarch64" ]; then
echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-${output_format})
GROUP ( ./libglibc-compatibility.a ../../lib/libc.so.6 ./libc_nonshared.a  AS_NEEDED ( ../../lib/ld-linux-aarch64.so.1 ) )
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
GROUP ( ./libglibc-compatibility.a ./libm-2.27.a ./libmvec.a )
" >toolchain/usr/lib/libm.a
cp -L /usr/lib/${ARCH}-linux-gnu/libm-2.27.a toolchain/usr/lib/
cp -L /usr/lib/${ARCH}-linux-gnu/libmvec.a toolchain/usr/lib/
elif [ "${ARCH}" = "aarch64" ]; then
    echo "/* GNU ld script
*/
OUTPUT_FORMAT(elf64-${output_format})
GROUP ( ./libglibc-compatibility.a ./libm-2.27.a )
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

sed -i "s/<LLVM_VERSION>/$LLVM_VERSION/" toolchain/bin/clang
sed -i "s/<LLVM_VERSION>/$LLVM_VERSION/" toolchain/bin/clang++

# Setup gcc toolchains

mkdir -p toolchain/lib/gcc/${ARCH}-linux-gnu/11

for f in /opt/exodus/bundles/*/usr/lib/gcc/${ARCH}-linux-gnu/11/*-x
do
    p=$(basename $f)
    g=${p::-2}
    cp -L $f toolchain/lib/gcc/${ARCH}-linux-gnu/11/$g
    ./patchelf --set-interpreter "$interpreter" --set-rpath '$ORIGIN/../../..' toolchain/lib/gcc/${ARCH}-linux-gnu/11/$g
done

cp -r -L /usr/lib/gcc/${ARCH}-linux-gnu/11/crtbegin.o \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/crtend.o \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/crtbeginT.o \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/crtbeginS.o \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/crtendS.o \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libgcc_eh.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libgcc.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libstdc++.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libstdc++fs.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libatomic.so \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libatomic.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/liblto_plugin.so \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libgcov.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libsanitizer.spec \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libasan_preinit.o \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libasan.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libasan.so \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libtsan.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libtsan.so \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libubsan.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/libubsan.so \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/liblsan_preinit.o \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/liblsan.a \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/liblsan.so \
         /usr/lib/gcc/${ARCH}-linux-gnu/11/include \
    toolchain/lib/gcc/${ARCH}-linux-gnu/11

# gomp
cp -r -L \
    /usr/lib/gcc/${ARCH}-linux-gnu/11/crtfastmath.o \
    /usr/lib/gcc/${ARCH}-linux-gnu/11/libgomp.a \
    /usr/lib/gcc/${ARCH}-linux-gnu/11/libgomp.so \
    /usr/lib/gcc/${ARCH}-linux-gnu/11/libgomp.spec \
    toolchain/lib/gcc/${ARCH}-linux-gnu/11

ln -s gcc/x86_64-linux-gnu/11/libgomp.so toolchain/lib/libgomp.so.1

if [ "${ARCH}" = "x86_64" ]; then
    cp -r -L \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtoffloadbegin.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtoffloadend.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtoffloadtable.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtprec32.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtprec64.o \
    /usr/lib/gcc/x86_64-linux-gnu/11/crtprec80.o \
    toolchain/lib/gcc/${ARCH}-linux-gnu/11
fi

for so in toolchain/lib/gcc/${ARCH}-linux-gnu/11/*.so
do
    ./patchelf --set-rpath '$ORIGIN/../../..' "$so"
done

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( ./libstdc++.a ./libstdc++fs.a )
" >toolchain/lib/gcc/${ARCH}-linux-gnu/11/libstdc++.so

echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( -lgcc -lgcc_eh )
" >toolchain/lib/gcc/${ARCH}-linux-gnu/11/libgcc_s.so

# Sometimes static linking might still link to libgcc_s. Use ld script to redirect.
echo "/* GNU ld script
   Use the shared library, but some functions are only in
   the static library.  */
GROUP ( -lgcc -lgcc_eh )
" >toolchain/lib/gcc/${ARCH}-linux-gnu/11/libgcc_s.a

mkdir -p toolchain/include/${ARCH}-linux-gnu/c++
mkdir -p toolchain/include/c++

cp -r /usr/include/${ARCH}-linux-gnu/c++/11 toolchain/include/${ARCH}-linux-gnu/c++/
cp -r /usr/include/c++/11 toolchain/include/c++/

# Setup clang resource includes

mkdir -p toolchain/lib/clang
cp -r -L /usr/lib/llvm-${LLVM_VERSION}/lib/clang/${LLVM_VERSION} toolchain/lib/clang/

# cp -r -L /usr/lib/clang/${LLVM_VERSION_FULL} toolchain/lib/clang/${LLVM_VERSION_FULL}

# for so in toolchain/lib/clang/${LLVM_VERSION_FULL}/lib/linux/*.so
# do
#     ./patchelf --set-rpath '$ORIGIN/../../../..' "$so"
# done

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
# printers for gcc
cp -r /usr/share/gcc toolchain/share/gdb/
# printers for clang
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
    /data/toolchain/bin/cmake ..
    make
    /data/toolchain/bin/ar x libglibc-compatibility.a
    /data/toolchain/bin/ld -relocatable ./*.o -o glibc-compatibility.o
) &> /dev/null

cp /glibc-compatibility/build/libglibc-compatibility.a /glibc-compatibility/build/glibc-compatibility.o toolchain/usr/lib/

tar czf toolchain.tgz toolchain

sed -i "s/\${ARCH}/$ARCH/g" /setup_toolchain.sh

cat /setup_toolchain.sh toolchain.tgz > ldb_toolchain_gen.sh

chmod +x ldb_toolchain_gen.sh
