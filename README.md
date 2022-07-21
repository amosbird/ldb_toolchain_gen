# Linux Distribution Based Toolchain Generator

## TLDR

LDB toolchain generator gives you a working gcc-11 and clang-13 environment with cmake 3.22. It helps compiling modern C++ projects like ClickHouse and Doris on almost any Linux distros. The installation file can be found in [Releases](https://github.com/amosbird/ldb_toolchain_gen/releases).

## How to install

1. Download `ldb_toolchain_gen.sh` from [Releases](https://github.com/amosbird/ldb_toolchain_gen/releases)

2. Execute the following command to generate LDB toolchain

``` bash
bash ldb_toolchain_gen.sh /path/to/ldb_toolchain/
```

`/path/to/ldb_toolchain/` is the directory where the toolchain is installed. The following directory structure will be created.

``` sh
├── bin
├── include
├── lib
├── share
├── test
└── usr
```

## FAQ

1. Why do I still see version `GLIBC_xxx' not found?

It might be related to extern libc weak symbol such as [this code](https://github.com/janbar/openssl-cmake/blob/d4634362820f874e1f1461c7f5d766b3ef968c67/crypto/rand/rand_unix.c#L373). The root cause is related to [how the linker processes symbols](https://maskray.me/blog/2021-06-20-linker-symbol-resolution). The ideal solution is removing weak attribute from libc symbol declarations.

2. Compiler/Linker doesn't work at all: Symbol not found in xxx.so?

Make sure `LD_LIBRARY_PATH` is not set.

---

> **Note**
> The following content describes how `ldb_toolchain_gen.sh` is made. There is no need for common users to pay attention. It might lead to unnecessary confusion.

## Introduction

**LDB toolchain generator** helps generate toolchains derived from well-known linux distributions (LDB toolchain). **LDB toolchain** contains binaries from well-known linux distributions, which are heavily tested and optimized. It avoids the docker dependency which usually complicates developing workflows. Projects adopting LDB toolchain will likely generate byte-identical binaries. It benefits testing and debugging due to 100% consistency. It also lowers the bar of contributing code, as large C/C++ projects are usually daunting to build compared to Java, Golang, Rust, etc.

There are projects like Crosstool-NG and Gentoo-Prefix which aim at bootstraping toolchains from scratch. They are for advanced use cases and take a tremendous amount of time to bootstrap. It's also hard to control the quality of self-compiled toolchains.

## Tools used by LDB toolchain generator

1. https://github.com/intoli/exodus
2. https://github.com/NixOS/patchelf

[Exodus](https://github.com/intoli/exodus) generates relocate Linux ELF binaries with wrappers and dependencies. Dependencies are recursively collected. Wrappers are usually good enough for common tools. However, toolchains like GCC and Clang relies heavily on `/proc/self` to re-exec the driver program multiple times, which will not work for `ld-linux` wrappers. As a result, we use [patchelf](https://github.com/NixOS/patchelf) to modify `PT_INTERP` and `RPATH`. Though `RPATH` can be relative to the binary's location, it's not possible to make a relocatable a.out that can tolerate changes to the absolute path of `ld-linux`. Thus, LDB toolchain generator requires user to specify a **toolchain prefix**.

## How to generate a LDB toolchain generator

The main branch illustrates how the generator assembles gcc-11 and clang-14 from ubuntu-18.04.

To actually generate the toolchain, the following steps can be used:

```
git clone https://github.com/amosbird/ldb_toolchain_gen

cd ldb_toolchain_gen

docker build . -t <your_toolchain_generator_tag>

docker run --rm -v </path/to/store/toolchain>:/data

# Concrete Example

git clone https://github.com/amosbird/ldb_toolchain_gen

cd ldb_toolchain_gen

# You may need http proxy to overcome network errors during docker build
docker build . -t amosbird/some_toolchain_gen
# docker build --network host --build-arg http_proxy=http://127.0.0.1:10000 --build-arg https_proxy=http://127.0.0.1:10000 . -t amosbird/some_toolchain_gen

mkdir /tmp/some_toolchain_gen

# You may need root privilege
docker run --rm -v /tmp/some_toolchain_gen:/data amosbird/some_toolchain_gen
```

In the end, `/tmp/some_toolchain_gen` will contain a install script: `ldb_toolchain_gen.sh`.

The main branch is currently used to build [ClickHouse](https://github.com/ClickHouse/ClickHouse) and [Doris](https://github.com/apache/incubator-doris).

If you want to generate a toolchain for the arm platform, you can change `ARCH=x86_64` in the `Dockerfile` to `ARCH=aarch64`.

## How to avoid GLIBC incompatibility

LDB toolchain might use newer libc which in turn will generate binaries that cannot be run on old host, even the same host for compilation. Users will encounter errors like `version GLIBC_2.27 not found`. A practical way of resolving this issue is described in [this wiki](http://www.lightofdawn.org/wiki/wiki.cgi/NewAppsOnOldGlibc).
