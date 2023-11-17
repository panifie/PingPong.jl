#!/usr/bin/env sh

echo "COMPILE_SCRIPT: $COMPILE_SCRIPT"
if [ -e "$COMPILE_SCRIPT" ]; then
    cp $COMPILE_SCRIPT /tmp/compile.jl
elif [ -n "$COMPILE_SCRIPT" ]; then
    /usr/bin/echo -e "$COMPILE_SCRIPT" > /tmp/compile.jl;
fi
