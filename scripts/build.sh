#!/usr/bin/env sh

set -e
tmppath=${BUILD_TMP_PATH:-/tmp/pingpnog-build}
# repo="https://github.com/panifie/PingPong.jl"
repo=${BUILD_REPO:-./PingPong.jl}

if [ ! -e "$tmppath" ]; then
    git clone --depth=1 "$repo" "$tmppath"
    cd $tmppath
    git submodule update --init
    direnv allow
fi

cp $tmppath/Dockerfile $repo/
cd $tmppath

${BUILD_RUNTIME:-docker} buildx build $@ -t pingpong .
