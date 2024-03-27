FROM ubuntu:18.04 AS generator

# Cannot use 20.04 with glibc 2.30 because of pthread_cond_clockwait etc.

ENV DEBIAN_FRONTEND=noninteractive GCC_VERSION=13 ARCH=x86_64

RUN apt-get update \
    && apt-get install ca-certificates lsb-release wget gnupg apt-transport-https software-properties-common \
        --yes --no-install-recommends --verbose-versions

RUN add-apt-repository -y ppa:ubuntu-toolchain-r/test

RUN apt-get update \
    && apt-get install \
        g++-${GCC_VERSION} \
        cmake \
        pkg-config \
        tzdata \
        python3-pip \
        python-dev \
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
        yasm \
        rsync \
        libltdl7 \
        vim \
        --yes --no-install-recommends

RUN if [ "${ARCH}" = "x86_64" ] ; then apt-get install g++-7-multilib --yes --no-install-recommends; fi

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

RUN wget https://github.com/Kitware/CMake/releases/download/v3.29.0/cmake-3.29.0-linux-${ARCH}.tar.gz -O /opt/cmake-3.29.0-linux-${ARCH}.tar.gz

RUN wget https://github.com/NixOS/patchelf/releases/download/0.14.3/patchelf-0.14.3-${ARCH}.tar.gz -O /opt/patchelf-0.14.3-${ARCH}.tar.gz

RUN if [ "${ARCH}" = "x86_64" ]; then wget https://github.com/apple/foundationdb/releases/download/7.1.59/foundationdb-clients_7.1.59-1_amd64.deb -O /opt/foundationdb-clients_7.1.59-1_amd64.deb && dpkg -i /opt/foundationdb-clients_7.1.59-1_amd64.deb; fi

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

RUN wget https://www.nasm.us/pub/nasm/releasebuilds/2.16.01/nasm-2.16.01.tar.gz -O /opt/nasm-2.16.01.tar.gz && \
    cd /opt && \
    tar zxf nasm-2.16.01.tar.gz && \
    cd nasm-2.16.01 && \
    ./configure --prefix=/usr && \
    make && \
    make install && \
    cd .. && \
    rm -rf nasm-2.16.01.tar.gz nasm-2.16.01

RUN wget https://github.com/ninja-build/ninja/archive/refs/tags/v1.11.1.tar.gz -O /opt/ninja-1.11.1.tar.gz && \
    cd /opt && \
    tar zxf ninja-1.11.1.tar.gz && \
    cd ninja-1.11.1 && \
    ./configure.py --bootstrap && \
    cp ninja /usr/bin/ && \
    cd .. && \
    rm -rf ninja-1.11.1.tar.gz ninja-1.11.1

ENV LLVM_VERSION=18

RUN echo "deb [trusted=yes] http://apt.llvm.org/bionic/ llvm-toolchain-bionic-${LLVM_VERSION} main" >> /etc/apt/sources.list

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
        libclang-rt-${LLVM_VERSION}-dev \
        --yes --no-install-recommends

RUN wget https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-$(/usr/lib/llvm-${LLVM_VERSION}/bin/clang --version  | head -n 1 | awk '{print $4}')/libcxx/utils/gdb/libcxx/printers.py -O /opt/printers.py

RUN exodus /usr/bin/yasm /usr/bin/nasm /usr/bin/nm /usr/bin/addr2line /usr/bin/python3 /usr/bin/curl /usr/bin/gdb /usr/bin/ninja \
    /usr/bin/m4 /usr/bin/bison /usr/bin/yacc /usr/bin/flex /usr/bin/pkg-config /usr/bin/as /usr/bin/ld.bfd \
    /usr/bin/gcc-ranlib-${GCC_VERSION} /usr/bin/g++-${GCC_VERSION} /usr/bin/gcc-ar-${GCC_VERSION} \
    /usr/bin/gcc-nm-${GCC_VERSION} \
    /usr/bin/gcc-${GCC_VERSION} \
    /usr/bin/${ARCH}-linux-gnu-cpp-${GCC_VERSION} \
    /usr/libexec/gcc/${ARCH}-linux-gnu/${GCC_VERSION}/lto1 \
    /usr/libexec/gcc/${ARCH}-linux-gnu/${GCC_VERSION}/lto-wrapper \
    /usr/libexec/gcc/${ARCH}-linux-gnu/${GCC_VERSION}/cc1 \
    /usr/libexec/gcc/${ARCH}-linux-gnu/${GCC_VERSION}/cc1plus \
    /usr/libexec/gcc/${ARCH}-linux-gnu/${GCC_VERSION}/collect2 \
    /usr/libexec/gcc/${ARCH}-linux-gnu/${GCC_VERSION}/g++-mapper-server \
    /usr/bin/lldb-argdumper-${LLVM_VERSION} \
    /usr/bin/lldb-instr-${LLVM_VERSION} \
    /usr/bin/lldb-server-${LLVM_VERSION} \
    /usr/bin/lldb-dap-${LLVM_VERSION} \
    /usr/bin/lldb-${LLVM_VERSION} \
    /usr/bin/clangd-${LLVM_VERSION} \
    /usr/bin/clang-tidy-${LLVM_VERSION} \
    /usr/bin/clang-format-${LLVM_VERSION} \
    /usr/bin/clang-cpp-${LLVM_VERSION} \
    /usr/bin/clang-${LLVM_VERSION} \
    /usr/lib/llvm-${LLVM_VERSION}/bin/llvm-link \
    /usr/lib/llvm-${LLVM_VERSION}/bin/llc \
    /usr/lib/llvm-${LLVM_VERSION}/bin/opt \
    /usr/bin/llvm-strip-${LLVM_VERSION} \
    /usr/bin/llvm-install-name-tool-${LLVM_VERSION} \
    /usr/bin/llvm-objcopy-${LLVM_VERSION} \
    /usr/bin/llvm-ranlib-${LLVM_VERSION} \
    /usr/bin/llvm-ar-${LLVM_VERSION} \
    /usr/bin/llvm-nm-${LLVM_VERSION} \
    /usr/bin/llvm-cov-${LLVM_VERSION} \
    /usr/bin/llvm-profdata-${LLVM_VERSION} \
    /usr/bin/llvm-profgen-${LLVM_VERSION} \
    /usr/bin/lld-${LLVM_VERSION} | bash

COPY generate_toolchain.sh setup_toolchain.sh disable_ld_preload.c /

RUN mkdir /wrappers

COPY tfg.py flamegraph bison ldb_gperf gcc g++ clang clang++ clangd curl /wrappers/

ADD tfg /wrappers/tfg

RUN mkdir /tests

COPY a.c /tests/

# __cxa_thread_atexit
# COPY libstdc++.a /tmp/libstdc++.a
# RUN if [ "${ARCH}" = "x86_64" ] ; then cp /tmp/libstdc++.a /usr/lib/gcc/x86_64-linux-gnu/11/libstdc++.a; fi

ADD glibc-compatibility /glibc-compatibility

WORKDIR /data

ENTRYPOINT [ "/generate_toolchain.sh" ]
