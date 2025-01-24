#!/usr/bin/env bash

export SHELL=/tmp/gentoo/bin/bash

RETAIN="HOME=$HOME TERM=$TERM USER=$USER SHELL=$SHELL"

env -i $RETAIN $SHELL -lc "$*"
