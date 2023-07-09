FROM julia:latest as base

RUN mkdir /pingpong \
    && useradd -u 1000 -G sudo -U -m -s /bin/bash ppuser \
    && chown ppuser:ppuser /pingpong \
    # Allow sudoers
    && echo "ppuser ALL=(ALL) NOPASSWD: /bin/chown" >> /etc/sudoers

RUN apt-get update && apt-get -y install direnv git

WORKDIR /pingpong
USER ppuser

FROM base as repos
ENV JULIA_LOAD_PATH=:/pingpong
COPY --chown=ppuser:ppuser ./ /pingpong/
RUN git submodule update --init

FROM repos as precompile1
RUN direnv allow
ENV JULIA_PROJECT=/pingpong/PingPong
ENV JULIA_CONDAPKG_ENV=/pingpong/.conda
ENV JULIA_NUM_THREADS=$(($(nproc)-2))
ENV JULIA_NOPRECOMP=""
ENV PINGPONG_LIQUIDATION_BUFFER=0.02
# Instantiate python env since CondaPkg is pulled from master
RUN julia --project=/pingpong/Python -e "import Pkg; Pkg.instantiate(); using Python"
# everything else...
RUN julia --project=/pingpong/PingPong -e "import Pkg; Pkg.instantiate();"

FROM precompile1 as precompile2
RUN julia --project=/pingpong/PingPong -e "include(\"resolve.jl\"); update_projects(io=devnull, inst=true)"
RUN julia --project=/pingpong/PingPong -e "using PingPong"

FROM precompile2 as pingpong
CMD [ "julia", "--project=/pingpong/PingPong" ]
