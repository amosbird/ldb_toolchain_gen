#!/usr/bin/env bash

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <toolchain_dir>"
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

cd "$dir"

for f in bin/*
do
    bin/patchelf --set-interpreter "$dir/lib/ld-linux-x86-64.so.2" --set-rpath '$ORIGIN/../lib' "$f" &> /dev/null || true
done

for f in cc1 cc1plus collect2 g++-mapper-server lto1 lto-wrapper
do
    bin/patchelf --set-interpreter "$dir/lib/ld-linux-x86-64.so.2" --set-rpath '$ORIGIN/../../..' "lib/gcc/x86_64-linux-gnu/11/$f" &> /dev/null || true
done

if ! bin/gcc test/a.c -o test/a; then
    echo "Generated toolchain cannot compile a simple program."
    echo "Please file an issue at https://github.com/amosbird/ldb_toolchain_gen/issues with current setup information."
    exit 1
fi

echo "Congratulations! LDB toolchain is setup at $dir. export PATH=\"$dir/bin\":\$PATH to take full advantage."
# JDK and Maven are too large
# echo "NOTE: openjdk and apache-maven are also provided under $dir"
echo "NOTE: LDB toolchain cannot be relocated to other directories manually. Instead, generate it again using $0"

exit 0

#EOF#
