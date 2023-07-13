#!/usr/bin/env sh

set -e
tmppath="/tmp/pingpong-docker"
# repo="https://github.com/panifie/PingPong.jl"
repo="$HOME/dev/PingPong.jl"

if [ ! -e "$tmppath" ]; then
    git clone --depth=1 "$repo" "$tmppath"
    cd $tmppath
    git submodule update --init
    direnv allow
fi

cp $tmppath/Dockerfile $repo/
cd $tmppath

sudo docker buildx build $@ -t pingpong .
