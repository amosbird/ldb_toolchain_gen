FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive LLVM_VERSION=13

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
        g++-11 \
        ninja-build \
        pkg-config \
        tzdata \
        llvm-${LLVM_VERSION} \
        clang-${LLVM_VERSION} \
        clang-tidy-${LLVM_VERSION} \
        lld-${LLVM_VERSION} \
        lldb-${LLVM_VERSION} \
        python3-pip \
        musl-tools \
        binutils-dev \
        libiberty-dev \
        --yes --no-install-recommends

RUN apt install git --yes --no-install-recommends

RUN wget https://github.com/Kitware/CMake/releases/download/v3.22.1/cmake-3.22.1-linux-x86_64.tar.gz -O /opt/cmake-3.22.1-linux-x86_64.tar.gz

RUN wget https://github.com/NixOS/patchelf/releases/download/0.14.3/patchelf-0.14.3-x86_64.tar.gz -O /opt/patchelf-0.14.3-x86_64.tar.gz

RUN pip3 install setuptools

RUN pip3 install git+https://github.com/intoli/exodus@ef3d5e92c1b604b09cf0a57baff0f4d0b421b8da

# Add extra binaries per project

RUN apt update && apt install libc++-13-dev libc++abi-13-dev --yes --no-install-recommends

RUN apt install flex --yes --no-install-recommends

RUN apt install autoconf --yes --no-install-recommends

RUN apt install clangd-${LLVM_VERSION} --yes --no-install-recommends

RUN apt install clang-format-${LLVM_VERSION} --yes --no-install-recommends

RUN apt install gdb --yes --no-install-recommends

RUN wget https://ftp.gnu.org/gnu/bison/bison-3.5.1.tar.gz -O /opt/bison-3.5.1.tar.gz && \
    cd /opt && \
    tar zxf bison-3.5.1.tar.gz && \
    cd bison-3.5.1 && \
    env M4=m4 ./configure --prefix /usr --enable-relocatable && \
    make && \
    make install && \
    cd .. && \
    rm -rf bison-3.5.1 bison-3.5.1.tar.gz

RUN apt install google-perftools --yes --no-install-recommends

RUN apt install libssl-dev --yes --no-install-recommends

RUN exodus /usr/bin/python3 /usr/bin/curl /usr/bin/gdb /usr/bin/lldb-argdumper-13 /usr/bin/lldb-instr-13 /usr/bin/lldb-server-13 /usr/bin/lldb-vscode-13 /usr/bin/lldb-13 /usr/bin/clangd-13 /usr/bin/clang-format-13 /usr/bin/clang-tidy-13 /usr/bin/m4 /usr/bin/bison /usr/bin/yacc /usr/bin/flex /usr/bin/pkg-config /usr/bin/as /usr/bin/ld.bfd /usr/bin/clang-cpp-13 /usr/bin/x86_64-linux-gnu-cpp-11 /usr/bin/gcc-ranlib-11 /usr/bin/g++-11 /usr/bin/gcc-ar-11 /usr/bin/gcc-nm-11 /usr/bin/gcc-11 /usr/bin/llvm-objdump-13 /usr/bin/llvm-objcopy-13 /usr/bin/llvm-ranlib-13 /usr/bin/llvm-ar-13 /usr/bin/llvm-nm-13 /usr/bin/clang-13 /usr/bin/lld-13 /usr/bin/ninja /usr/lib/gcc/x86_64-linux-gnu/11/lto1 /usr/lib/gcc/x86_64-linux-gnu/11/lto-wrapper /usr/lib/gcc/x86_64-linux-gnu/11/g++-mapper-server /usr/lib/gcc/x86_64-linux-gnu/11/cc1 /usr/lib/gcc/x86_64-linux-gnu/11/cc1plus /usr/lib/gcc/x86_64-linux-gnu/11/collect2 | bash

RUN cp /usr/lib/libsource-highlight.so.4 /opt/exodus/bundles/*/usr/lib/x86_64-linux-gnu/

COPY generate_toolchain.sh setup_toolchain.sh disable_ld_preload.c /

RUN mkdir /wrappers

COPY tfg.py flamegraph bison ldb_gperf gcc g++ clang clang++ /wrappers/

ADD tfg /wrappers/tfg

RUN mkdir /tests

COPY a.c /tests/

ADD glibc-compatibility /glibc-compatibility

WORKDIR /data

ENTRYPOINT [ "/generate_toolchain.sh" ]
