#!/usr/bin/env bash

set -e

verbose=false
old_abi=false

help_message="Usage: $0 [OPTIONS] <toolchain_dir>
Options:
  -h, --help     Display this help message and exit.
  -v, --verbose  Enable verbose mode.
  -o, --old-abi  Use old ABI (Application Binary Interface)."

while getopts ":hvo" opt; do
  case $opt in
    h)
      echo "$help_message"
      exit 0
      ;;
    v)
      verbose=true
      ;;
    o)
      old_abi=true
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

shift $((OPTIND -1))

if [ -z "$1" ]; then
    echo "$help_message"
    exit 1
fi

dir=$1

if [[ ! "$dir" = "/"* ]]; then
    echo "toolchain_dir should be an absolute PATH"
    exit 1
fi

if [[ -e "$dir" ]]; then
    echo "$dir already exists"
    exit 1
fi

prefix=$(dirname "$dir")

tmpdir=$(mktemp -p "$prefix" -d -q -t ".ldb_toolchain_XXXXXX")

if [ ! $? -eq 0 ]; then
    echo "Cannot create directory under $prefix."
    exit 1
fi

trap "rm -rf -- '$tmpdir'" EXIT

sed '0,/^#EOF#$/d' "$0" | tar zx --strip-components=1 -C "$tmpdir"

mv "$tmpdir" "$dir"
chmod a+rx "$dir"

cd "$dir"
interpreter=""
if [ "${ARCH}" == "x86_64" ]; then
    interpreter="$dir/lib/ld-linux-x86-64.so.2"
elif [ "${ARCH}" == "aarch64" ]; then
    interpreter="$dir/lib/ld-linux-aarch64.so.1"
else
    echo "Unknown architecture: ${ARCH}"
    exit 1
fi
for f in bin/*
do
    bin/patchelf --set-interpreter "$interpreter" --set-rpath '$ORIGIN/../lib' "$f" &> /dev/null || true
done

for f in tmp/gentoo/bin/*
do
    bin/patchelf --set-interpreter "$interpreter" --set-rpath '$ORIGIN/../../../lib' "$f" &> /dev/null || true
done

for f in tmp/gentoo/llvm/bin/*
do
    bin/patchelf --set-interpreter "$interpreter" --set-rpath '$ORIGIN/../../../../lib' "$f" &> /dev/null || true
done

for f in cc1 cc1plus collect2 g++-mapper-server lto1 lto-wrapper
do
    bin/patchelf --set-interpreter "$interpreter" --set-rpath '$ORIGIN/../../../../lib' "libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/$f" &> /dev/null || true
done

bin/patchelf --set-rpath '$ORIGIN/../../../../lib' "libexec/gcc/${ARCH}-unknown-linux-gnu/${GCC_VERSION}/liblto_plugin.so" &> /dev/null || true

for c in clang clang++ gcc g++
do
    if $old_abi; then
        sed -i "s/<OLD_ABI>/-no-pie -D_GLIBCXX_USE_CXX11_ABI=0/" bin/$c
    else
        sed -i "s/<OLD_ABI>//" bin/$c
    fi
done

if ! bin/gcc test/a.c -o test/a; then
    echo "Generated toolchain (gcc) cannot compile a simple program."
    echo "Please file an issue at https://github.com/amosbird/ldb_toolchain_gen/issues with current setup information."
    exit 1
fi

if ! bin/clang test/a.c -o test/a; then
    echo "Generated toolchain (clang) cannot compile a simple program."
    echo "Please file an issue at https://github.com/amosbird/ldb_toolchain_gen/issues with current setup information."
    exit 1
fi

echo "Congratulations! LDB toolchain is setup at $dir. export PATH=\"$dir/bin\":\$PATH to take full advantage."
# JDK and Maven are too large
# echo "NOTE: openjdk and apache-maven are also provided under $dir"
echo "NOTE: LDB toolchain cannot be relocated to other directories manually. Instead, generate it again using $0"

exit 0

#EOF#
