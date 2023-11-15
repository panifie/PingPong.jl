FROM julia:rc as base
RUN mkdir /pingpong \
    && apt-get update \
    && apt-get -y install sudo direnv git xvfb \
    && useradd -u 1000 -G sudo -U -m -s /bin/bash ppuser \
    && chown ppuser:ppuser /pingpong \
    # Allow sudoers
    && echo "ppuser ALL=(ALL) NOPASSWD: /bin/chown" >> /etc/sudoers
WORKDIR /pingpong
USER ppuser
ARG CPU_TARGET=generic
ARG JULIA_CMD="julia -C $CPU_TARGET"
ENV JULIA_CMD=$JULIA_CMD
ENV JULIA_CPU_TARGET ${CPU_TARGET}
CMD julia -C $JULIA_CPU_TARGET

FROM base as python1
ENV JULIA_LOAD_PATH=:/pingpong
ENV JULIA_CONDAPKG_ENV=/pingpong/.conda
# avoids progressbar spam
ENV CI=true
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
ENV JULIA_PRECOMP=Remote,PaperMode,LiveMode,Fetch,Optimization,Plotting
ENV PINGPONG_LIQUIDATION_BUFFER=0.02
ARG CACHE=1
RUN $JULIA_CMD --project=/pingpong/PingPong -e "import Pkg; Pkg.instantiate()"

FROM precompile1 as precompile2
RUN JULIA_PROJECT= $JULIA_CMD -e "import Pkg; Pkg.add([\"DataFrames\", \"CSV\", \"Makie\", \"WGLMakie\", \"ZipFile\"])"

FROM precompile2 as precompile3
COPY --chown=ppuser:ppuser ./ /pingpong/
RUN git submodule update --init

FROM precompile3 as precomp-base
USER ppuser
WORKDIR /pingpong
ENV JULIA_NUM_THREADS=1
CMD julia -C $JULIA_CPU_TARGET

FROM precomp-base as pingpong-precomp
ENV JULIA_PROJECT=/pingpong/PingPong
RUN $JULIA_CMD -e "import Pkg; Pkg.instantiate(); using PingPong; using Stats"

FROM pingpong-precomp as pingpong-precomp-interactive
ENV JULIA_PROJECT=/pingpong/PingPongInteractive
RUN $JULIA_CMD -e "import Pkg; Pkg.instantiate(); using PingPongInteractive"

FROM pingpong-precomp as pingpong-sysimg
USER root
RUN apt-get install -y gcc g++
ENV JULIA_PROJECT=/pingpong/user/Load
ARG COMPILE_SCRIPT
RUN /usr/bin/echo -e "$COMPILE_SCRIPT" > /tmp/compile.jl; \
    su ppuser -c "cd /pingpong; \
    . .envrc; \
    $JULIA_CMD -e \
    'include(\"/tmp/compile.jl\"); compile(\"user/Load\"; cpu_target=\"$JULIA_CPU_TARGET\")'"; \
    rm /tmp/compile.jl
USER ppuser
ENV JULIA_PROJECT=/pingpong/PingPong
# Resets condapkg env
RUN $JULIA_CMD --sysimage "/pingpong/PingPong.so" -e "using PingPong"
CMD $JULIA_CMD --sysimage "/pingpong/PingPong.so"

FROM pingpong-precomp-interactive as pingpong-sysimg-interactive
USER root
ENV JULIA_PROJECT=/pingpong/PingPongInteractive
RUN apt-get install -y gcc g++
ARG COMPILE_SCRIPT
RUN /usr/bin/echo -e "$COMPILE_SCRIPT" > /tmp/compile.jl; \
    su ppuser -c ". .envrc; \
    $JULIA_CMD -e 'include(\"/tmp/compile.jl\"); compile(\"PingPongInteractive\"; cpu_target=\"$JULIA_CPU_TARGET\")'"; \
    rm /tmp/compile.jl
USER ppuser
# Resets condapkg env
RUN $JULIA_CMD --sysimage "/pingpong/PingPong.so" -e "using PingPongInteractive"
CMD $JULIA_CMD --sysimage PingPong.so

# FROM precomp-base as sysimg-base
# ENV JULIA_NUM_THREADS=auto

# FROM sysimg-base as pingpong-sysimg-interactive
# ENV JULIA_PROJECT=/pingpong/IPingPong
# COPY --chown=ppuser:ppuser --from=sysimg /pingpong/IPingPong.so /pingpong/
# CMD [ "julia", "-C", $JULIA_CPU_TARGET, "-J", "/pingpong/IPingPong.so" ]

# FROM sysimg-base as pingpong-sysimg
# ENV JULIA_PROJECT=/pingpong/IPingPong
# COPY --chown=ppuser:ppuser --from=sysimg /pingpong/PingPong.so /pingpong/
# CMD [ "julia", "-C", $JULIA_CPU_TARGET, "-J", "/pingpong/PingPong.so" ]
