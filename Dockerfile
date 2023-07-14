FROM julia:latest as base
RUN mkdir /pingpong \
    && apt-get update \
    && apt-get -y install sudo direnv git xvfb \
    && useradd -u 1000 -G sudo -U -m -s /bin/bash ppuser \
    && chown ppuser:ppuser /pingpong \
    # Allow sudoers
    && echo "ppuser ALL=(ALL) NOPASSWD: /bin/chown" >> /etc/sudoers
WORKDIR /pingpong
USER ppuser
ARG CPU_TARGET=znver2
ARG JULIA_CMD="julia -C $CPU_TARGET"

FROM base as python1
ENV JULIA_CPU_TARGET=$CPU_TARGET
ENV JULIA_LOAD_PATH=:/pingpong
ENV JULIA_CONDAPKG_ENV=/pingpong/.conda
COPY --chown=ppuser:ppuser ./Python/*.toml /pingpong/Python/
# Instantiate python env since CondaPkg is pulled from master
ARG CACHE=1
RUN $JULIA_CMD --project=/pingpong/Python -e "import Pkg; Pkg.instantiate()"
COPY --chown=ppuser:ppuser ./Python /pingpong/Python
RUN $JULIA_CMD --project=/pingpong/Python -e "using Python"

FROM python1 as precompile1
COPY --chown=ppuser:ppuser ./PingPong/*.toml /pingpong/PingPong/
ENV JULIA_PROJECT=/pingpong/PingPong
ENV JULIA_NOPRECOMP=""
ENV PINGPONG_LIQUIDATION_BUFFER=0.02
ARG CACHE=1
RUN $JULIA_CMD --project=/pingpong/PingPong -e "import Pkg; Pkg.instantiate()"

FROM precompile1 as precompile2
RUN JULIA_PROJECT= $JULIA_CMD -e "import Pkg; Pkg.add([\"DataFrames\", \"CSV\", \"Rocket\", \"Makie\", \"WGLMakie\", \"ZipFile\"])"

FROM precompile2 as precompile3
COPY --chown=ppuser:ppuser . /pingpong/
RUN git submodule update --init

FROM precompile3 as sysimg
USER root
RUN apt-get install -y gcc g++
RUN su ppuser -c "unset JULIA_PROJECT; xvfb-run $JULIA_CMD compile.jl"

FROM precompile3 as precomp-base
USER ppuser
WORKDIR /pingpong
ENV JULIA_NUM_THREADS=1
CMD [ "julia", "-C", $JULIA_CPU_TARGET ]

FROM precomp-base as pingpong-precomp-interactive
ENV JULIA_PROJECT=/pingpong/IPingPong
RUN $JULIA_CMD -e "using IPingPong"

FROM precomp-base as pingpong-precomp
ENV JULIA_PROJECT=/pingpong/PingPong
RUN $JULIA_CMD -e "using PingPong"

FROM precomp-base as sysimg-base
ENV JULIA_NUM_THREADS=auto

FROM sysimg-base as pingpong-sysimg-interactive
ENV JULIA_PROJECT=/pingpong/IPingPong
COPY --chown=ppuser:ppuser --from=sysimg /pingpong/IPingPong.so /pingpong/
CMD [ "julia", "-C", $JULIA_CPU_TARGET, "-J", "/pingpong/IPingPong.so" ]

FROM sysimg-base as pingpong-sysimg
ENV JULIA_PROJECT=/pingpong/IPingPong
COPY --chown=ppuser:ppuser --from=sysimg /pingpong/PingPong.so /pingpong/
CMD [ "julia", "-C", $JULIA_CPU_TARGET, "-J", "/pingpong/PingPong.so" ]
