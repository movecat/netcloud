FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 \
        libsodium23 \
        net-tools \
        procps \
        tzdata; \
    rm -rf /var/lib/apt/lists/*; \
    python -m pip install --no-cache-dir PyMySQL

# install.sh / `kcloud-ssr update` check out movecat/shadowsocksr-manyuser (branch SSR_REF) into ./ssr.
COPY ssr/ /usr/local/shadowsocks/
COPY docker-entrypoint.sh /usr/local/bin/kcloud-entrypoint

RUN chmod +x /usr/local/bin/kcloud-entrypoint; \
    rm -rf /usr/local/shadowsocks/.git; \
    mkdir -p /data /var/log/kcloud

WORKDIR /usr/local/shadowsocks

ENTRYPOINT ["kcloud-entrypoint"]
CMD ["run"]
