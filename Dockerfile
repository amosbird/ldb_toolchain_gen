FROM ubuntu:18.04 AS generator

RUN apt-get update

RUN apt-get install apt-utils sudo -y

# Create user
RUN useradd --create-home --shell=/bin/bash user
RUN chown -R user /home/user/
# Add the user to sudoers
RUN chmod -R o-w /etc/sudoers.d/
RUN usermod -aG sudo user
# Give the user a password
RUN echo user:user | chpasswd

RUN apt-get install build-essential wget -y

ENV ARCH=aarch64

# some packages like libcrypt and libcxx has a regression which failed to build without -lpthread because newer glibc provides everything in libc.so
RUN sed -i "s=libc_nonshared.a=libc_nonshared.a /lib/${ARCH}-linux-gnu/libpthread.so.0 /usr/lib/${ARCH}-linux-gnu/libpthread_nonshared.a=" /usr/lib/${ARCH}-linux-gnu/libc.so

WORKDIR /data
USER user

COPY bootstrap-prefix.sh /data/

RUN PREFIX_DISABLE_RAP=yes STOP_BOOTSTRAP_AFTER=stage1 bash bootstrap-prefix.sh /tmp/gentoo noninteractive

RUN truncate -s 0 /tmp/gentoo/var/db/repos/gentoo/profiles/package.mask

# Disable __cxa_thread_atexit_impl
COPY portage_bashrc /tmp/gentoo/tmp/etc/portage/bashrc

# Aarch64 only
RUN ln -s /tmp/gentoo/tmp/usr/lib /tmp/gentoo/tmp/usr/lib64 

COPY package.accept_keywords /tmp/gentoo/tmp/etc/portage/package.accept_keywords

RUN PREFIX_DISABLE_RAP=yes STOP_BOOTSTRAP_AFTER=stage2 bash bootstrap-prefix.sh /tmp/gentoo noninteractive

# Disable __cxa_thread_atexit_impl
COPY portage_bashrc /tmp/gentoo/etc/portage/bashrc

# Aarch64 only
RUN ln -s /tmp/gentoo/usr/lib /tmp/gentoo/usr/lib64 

COPY package_stage3.accept_keywords /tmp/gentoo/etc/portage/package.accept_keywords

RUN echo 'PYTHON_TARGETS="python3_12"' >> /tmp/gentoo/etc/portage/make.conf/0100_bootstrap_prefix_make.conf

RUN PREFIX_DISABLE_RAP=yes STOP_BOOTSTRAP_AFTER=stage3 bash bootstrap-prefix.sh /tmp/gentoo noninteractive

RUN PREFIX_DISABLE_RAP=yes bash bootstrap-prefix.sh /tmp/gentoo noninteractive

USER root

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get install \
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
    zlib1g-dev \
    libtinfo-dev \
    libffi-dev \
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

RUN wget https://mirrors.tuna.tsinghua.edu.cn/gnu/bison/bison-3.5.1.tar.gz -O /opt/bison-3.5.1.tar.gz && \
    cd /opt && \
    tar zxf bison-3.5.1.tar.gz && \
    cd bison-3.5.1 && \
    env M4=m4 ./configure --prefix /usr --enable-relocatable && \
    make && \
    make install && \
    cd .. && \
    rm -rf bison-3.5.1 bison-3.5.1.tar.gz

COPY execute-prefix.sh /data/

RUN mkdir -p /tmp/gentoo/etc/portage/env

RUN bash -c "echo 'MYCMAKEARGS=\"\${MYCMAKEARGS} -DLIBOMP_ENABLE_SHARED=OFF\"' > /tmp/gentoo/etc/portage/env/openmp-static.conf"

RUN bash -c 'echo llvm-runtimes/openmp openmp-static.conf > /tmp/gentoo/etc/portage/package.env'

COPY portage_bashrc2 /tmp/gentoo/etc/portage/bashrc

ENV GCC_VERSION=15 LLVM_VERSION=20

RUN mkdir -p /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/lib

RUN ln -s /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/lib /tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/lib64

RUN echo 'FEATURES="-qa ${FEATURES}"' >> /tmp/gentoo/etc/portage/make.conf/0100_bootstrap_prefix_make.conf

RUN bash execute-prefix.sh emerge nasm libcxx lldb sys-libs/libunwind llvm-core/clang lld gdb llvm-runtimes/openmp

RUN bash execute-prefix.sh emerge --sync
 
RUN bash execute-prefix.sh emerge --update --deep --changed-use @world

RUN wget https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-$(/tmp/gentoo/usr/lib/llvm/${LLVM_VERSION}/bin/clang --version  | head -n 1 | awk '{print $3}')/libcxx/utils/gdb/libcxx/printers.py -O /opt/printers.py

RUN apt-get install libunwind-dev --yes --no-install-recommends

COPY generate_toolchain.sh setup_toolchain.sh disable_ld_preload.c /

RUN mkdir /wrappers

COPY tfg.py flamegraph bison ldb_gperf gcc g++ clang clang++ clangd curl /wrappers/

ADD tfg /wrappers/tfg

RUN mkdir /tests

COPY a.c /tests/

COPY FindThrift.cmake /

ADD glibc-compatibility /glibc-compatibility

WORKDIR /data

ENTRYPOINT [ "/generate_toolchain.sh" ]
