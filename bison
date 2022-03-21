#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

export PATH="$DIR":$PATH
export LD_PRELOAD=
export M4="$DIR/m4"
export BISON_PKGDATADIR="$DIR/../share/bison"

exec "$DIR/bison-3.5.1" "$@"
