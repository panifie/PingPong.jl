#!/usr/bin/env bash

set -e
tmppath=${BUILD_TMP_PATH:-/tmp/pingpong-build}
# repo="https://github.com/panifie/PingPong.jl"
repo=${BUILD_REPO:-.}
image=${1:-${BUILD_IMAGE:-pingpong}}
if [ -n "$2" ]; then
    shift
fi

if [ ! -e "$tmppath" ]; then
    git clone --depth=1 "$repo" "$tmppath"
    cd $tmppath
    git submodule update --init
    direnv allow
fi

cp $tmppath/Dockerfile $repo/ || true
cd $tmppath

# COMPILE_SCRIPT=$'$(<compile.jl)\n'
COMPILE_SCRIPT="$(sed "s/$/\\\\n/" "$repo/scripts/compile.jl")"

${BUILD_RUNTIME:-docker} buildx build "$@" --build-arg=COMPILE_SCRIPT="'$COMPILE_SCRIPT'" -t "$image" .
