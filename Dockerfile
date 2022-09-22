FROM ubuntu:18.04 AS generator

ENV DEBIAN_FRONTEND=noninteractive LLVM_VERSION=14 LLVM_VERSION_FULL=14.0.6 ARCH=x86_64

RUN apt-get update \
    && apt-get install ca-certificates lsb-release wget gnupg apt-transport-https software-properties-common \
        --yes --no-install-recommends --verbose-versions \
    && export LLVM_PUBKEY_HASH="bda960a8da687a275a2078d43c111d66b1c6a893a3275271beedf266c1ff4a0cdecb429c7a5cccf9f486ea7aa43fd27f" \
    && wget -nv -O /tmp/llvm-snapshot.gpg.key https://apt.llvm.org/llvm-snapshot.gpg.key \
    && echo "${LLVM_PUBKEY_HASH} /tmp/llvm-snapshot.gpg.key" | sha384sum -c \
    && apt-key add /tmp/llvm-snapshot.gpg.key \
    && export CODENAME="$(lsb_release --codename --short | tr 'A-Z' 'a-z')" \
    && echo "deb [trusted=yes] http://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-${LLVM_VERSION} main" >> \
        /etc/apt/sources.list

RUN add-apt-repository -y ppa:ubuntu-toolchain-r/test

RUN apt-get update \
    && apt-get install \
        llvm-${LLVM_VERSION}-dev \
        clang-${LLVM_VERSION} \
        clang-format-${LLVM_VERSION} \
        clang-tidy-${LLVM_VERSION} \
        lld-${LLVM_VERSION} \
        lldb-${LLVM_VERSION} \
        libc++-${LLVM_VERSION}-dev libc++abi-${LLVM_VERSION}-dev \
        clangd-${LLVM_VERSION} \
        g++-11 \
        ninja-build \
        pkg-config \
        tzdata \
        python3-pip \
        musl-tools \
        binutils-dev \
        libiberty-dev \
        build-essential \
        fakeroot \
        dpkg-dev \
        git \
        flex \
        autoconf \
        gdb \
        google-perftools \
        libssl-dev \
        gettext \
        file \
        quilt \
        gawk \
        debhelper \
        rdfind \
        symlinks \
        netbase \
        gperf \
        bison \
        systemtap-sdt-dev \
        libaudit-dev \
        libcap-dev \
        libselinux-dev \
        po-debconf \
        --yes --no-install-recommends

RUN if [ "${ARCH}" = "x86_64" ] ; then apt-get install g++-7-multilib --yes --no-install-recommends; fi

RUN wget https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-${LLVM_VERSION_FULL}/libcxx/utils/gdb/libcxx/printers.py -O /opt/printers.py

FROM generator AS glibc

WORKDIR /opt

RUN wget https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/glibc/2.27-3ubuntu1.6/glibc_2.27-3ubuntu1.6.dsc

RUN wget https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/glibc/2.27-3ubuntu1.6/glibc_2.27.orig.tar.xz

RUN wget https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/glibc/2.27-3ubuntu1.6/glibc_2.27-3ubuntu1.6.debian.tar.xz

RUN dpkg-source -x glibc_2.27-3ubuntu1.6.dsc

WORKDIR /opt/glibc-2.27

RUN sed -i "s/if (__glibc_unlikely (__access (preload_file, R_OK) == 0))/if (false)/" elf/rtld.c

RUN DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -rfakeroot -b

FROM generator

COPY --from=glibc /opt/libc6_2.27-3ubuntu1.6_*.deb /opt/

RUN dpkg -i /opt/libc6_2.27-3ubuntu1.6_*.deb

RUN wget https://github.com/Kitware/CMake/releases/download/v3.22.1/cmake-3.22.1-linux-${ARCH}.tar.gz -O /opt/cmake-3.22.1-linux-${ARCH}.tar.gz

RUN wget https://github.com/NixOS/patchelf/releases/download/0.14.3/patchelf-0.14.3-${ARCH}.tar.gz -O /opt/patchelf-0.14.3-${ARCH}.tar.gz

RUN pip3 install setuptools

RUN pip3 install git+https://github.com/intoli/exodus@ef3d5e92c1b604b09cf0a57baff0f4d0b421b8da

RUN wget https://ftp.gnu.org/gnu/bison/bison-3.5.1.tar.gz -O /opt/bison-3.5.1.tar.gz && \
    cd /opt && \
    tar zxf bison-3.5.1.tar.gz && \
    cd bison-3.5.1 && \
    env M4=m4 ./configure --prefix /usr --enable-relocatable && \
    make && \
    make install && \
    cd .. && \
    rm -rf bison-3.5.1 bison-3.5.1.tar.gz

RUN exodus /usr/bin/nm /usr/bin/addr2line /usr/bin/python3 /usr/bin/curl /usr/bin/gdb /usr/bin/llvm-strip-${LLVM_VERSION} /usr/bin/llvm-install-name-tool-${LLVM_VERSION} /usr/bin/lldb-argdumper-${LLVM_VERSION} /usr/bin/lldb-instr-${LLVM_VERSION} /usr/bin/lldb-server-${LLVM_VERSION} /usr/bin/lldb-vscode-${LLVM_VERSION} /usr/bin/lldb-${LLVM_VERSION} /usr/bin/clangd-${LLVM_VERSION} /usr/bin/clang-tidy-${LLVM_VERSION} /usr/bin/clang-format-${LLVM_VERSION} /usr/bin/m4 /usr/bin/bison /usr/bin/yacc /usr/bin/flex /usr/bin/pkg-config /usr/bin/as /usr/bin/ld.bfd /usr/bin/clang-cpp-${LLVM_VERSION} /usr/bin/${ARCH}-linux-gnu-cpp-10 /usr/bin/gcc-ranlib-10 /usr/bin/g++-10 /usr/bin/gcc-ar-10 /usr/bin/gcc-nm-10 /usr/bin/gcc-10 /usr/bin/llvm-objdump-${LLVM_VERSION} /usr/bin/llvm-objcopy-${LLVM_VERSION} /usr/bin/llvm-ranlib-${LLVM_VERSION} /usr/bin/llvm-ar-${LLVM_VERSION} /usr/bin/llvm-nm-${LLVM_VERSION} /usr/bin/clang-${LLVM_VERSION} /usr/bin/lld-${LLVM_VERSION} /usr/bin/ninja /usr/lib/gcc/${ARCH}-linux-gnu/10/lto1 /usr/lib/gcc/${ARCH}-linux-gnu/10/lto-wrapper /usr/lib/gcc/${ARCH}-linux-gnu/10/cc1 /usr/lib/gcc/${ARCH}-linux-gnu/10/cc1plus /usr/lib/gcc/${ARCH}-linux-gnu/10/collect2 | bash

RUN cp /usr/lib/libsource-highlight.so.4 /opt/exodus/bundles/*/usr/lib/${ARCH}-linux-gnu/

COPY generate_toolchain.sh setup_toolchain.sh disable_ld_preload.c /

RUN mkdir /wrappers

COPY tfg.py flamegraph bison ldb_gperf gcc g++ clang clang++ curl /wrappers/

ADD tfg /wrappers/tfg

RUN mkdir /tests

COPY a.c /tests/

ADD glibc-compatibility /glibc-compatibility

WORKDIR /data

ENTRYPOINT [ "/generate_toolchain.sh" ]
