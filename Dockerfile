FROM julia:latest as base

RUN mkdir /pingpong \
    && useradd -u 1000 -G sudo -U -m -s /bin/bash ppuser \
    && chown ppuser:ppuser /pingpong \
    # Allow sudoers
    && echo "ppuser ALL=(ALL) NOPASSWD: /bin/chown" >> /etc/sudoers

WORKDIR /pingpong
USER ppuser

FROM base as pingpong
COPY ./* /pingpong/
