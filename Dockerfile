FROM julia:1.11 as base
RUN mkdir /pingpong \
    && apt-get update \
    && apt-get -y install sudo direnv git \
    && useradd -u 1000 -G sudo -U -m -s /bin/bash ppuser \
    && chown ppuser:ppuser /pingpong \
    # Allow sudoers
    && echo "ppuser ALL=(ALL) NOPASSWD: /bin/chown" >> /etc/sudoers
WORKDIR /pingpong
USER ppuser
ARG CPU_TARGET=generic
ENV JULIA_BIN=/usr/local/julia/bin/julia
ARG JULIA_CMD="$JULIA_BIN -C $CPU_TARGET"
ENV JULIA_CMD=$JULIA_CMD
ENV JULIA_CPU_TARGET ${CPU_TARGET}

# PINGPONG ENV VARS GO HERE
ENV PINGPONG_LIQUIDATION_BUFFER=0.02
ENV JULIA_NOPRECOMP=""
ENV JULIA_PRECOMP=Remote,PaperMode,LiveMode,Fetch,Optimization,Plotting
CMD $JULIA_BIN -C $JULIA_CPU_TARGET

FROM base as python1
ENV JULIA_LOAD_PATH=:/pingpong
ENV JULIA_CONDAPKG_ENV=/pingpong/user/.conda
# avoids progressbar spam
ENV CI=true
COPY --chown=ppuser:ppuser ./Lang/ /pingpong/Lang/
COPY --chown=ppuser:ppuser ./Python/*.toml /pingpong/Python/
# Instantiate python env since CondaPkg is pulled from master
ARG CACHE=1
RUN $JULIA_CMD --project=/pingpong/Python -e "import Pkg; Pkg.instantiate()"
COPY --chown=ppuser:ppuser ./Python /pingpong/Python
RUN $JULIA_CMD --project=/pingpong/Python -e "using Python"

FROM python1 as precompile1
COPY --chown=ppuser:ppuser ./PingPong/*.toml /pingpong/PingPong/
ENV JULIA_PROJECT=/pingpong/PingPong
ARG CACHE=1
RUN $JULIA_CMD --project=/pingpong/PingPong -e "import Pkg; Pkg.instantiate()"

FROM precompile1 as precompile2
RUN JULIA_PROJECT= $JULIA_CMD -e "import Pkg; Pkg.add([\"DataFrames\", \"CSV\", \"ZipFile\"])"

FROM precompile2 as precompile3
COPY --chown=ppuser:ppuser ./ /pingpong/
RUN git submodule update --init

FROM precompile3 as precomp-base
USER ppuser
WORKDIR /pingpong
ENV JULIA_NUM_THREADS=auto
CMD $JULIA_BIN -C $JULIA_CPU_TARGET

FROM precomp-base as pingpong-precomp
ENV JULIA_PROJECT=/pingpong/PingPong
RUN $JULIA_CMD -e "import Pkg; Pkg.instantiate()"
RUN $JULIA_CMD -e "using PingPong; using Metrics"
RUN $JULIA_CMD -e "using Metrics"

FROM pingpong-precomp as pingpong-precomp-interactive
ENV JULIA_PROJECT=/pingpong/PingPongInteractive
RUN JULIA_PROJECT= $JULIA_CMD -e "import Pkg; Pkg.add([\"Makie\", \"WGLMakie\"])"
RUN $JULIA_CMD -e "import Pkg; Pkg.instantiate()"
RUN $JULIA_CMD -e "using PingPongInteractive"


FROM pingpong-precomp as pingpong-sysimage
USER root
RUN apt-get install -y gcc g++
ENV JULIA_PROJECT=/pingpong/user/Load
ARG COMPILE_SCRIPT
RUN scripts/docker_compile.sh; \
    su ppuser -c "cd /pingpong; \
    . .envrc; \
    cat /tmp/compile.jl; \
    $JULIA_CMD -e \
    'include(\"/tmp/compile.jl\"); compile(\"user/Load\"; cpu_target=\"$JULIA_CPU_TARGET\")'"; \
    rm -rf /tmp/compile.jl
USER ppuser
ENV JULIA_PROJECT=/pingpong/PingPong
# Resets condapkg env
RUN $JULIA_CMD --sysimage "/pingpong/PingPong.so" -e "using PingPong"
CMD $JULIA_CMD --sysimage "/pingpong/PingPong.so"

FROM pingpong-precomp-interactive as pingpong-sysimage-interactive
USER root
ENV JULIA_PROJECT=/pingpong/PingPongInteractive
RUN apt-get install -y gcc g++
ARG COMPILE_SCRIPT
RUN scripts/docker_compile.sh; \
    su ppuser -c "cd /pingpong; \
    . .envrc; \
    cat /tmp/compile.jl; \
    $JULIA_CMD -e \
    'include(\"/tmp/compile.jl\"); compile(\"PingPongInteractive\"; cpu_target=\"$JULIA_CPU_TARGET\")'"; \
    rm -rf /tmp/compile.jl
USER ppuser
# Resets condapkg env
RUN $JULIA_CMD --sysimage "/pingpong/PingPong.so" -e "using PingPongInteractive"
CMD $JULIA_CMD --sysimage PingPong.so
