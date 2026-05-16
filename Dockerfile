FROM python:3.9-slim-bullseye

ARG SSR_REPO=https://github.com/movecat/shadowsocksr-manyuser.git
ARG SSR_REF=master

ENV PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        iproute2 \
        libsodium23 \
        net-tools \
        procps \
        tzdata; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    git clone --depth=1 --branch "${SSR_REF}" "${SSR_REPO}" /usr/local/shadowsocks; \
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel; \
    python -m pip install --no-cache-dir PyMySQL; \
    python -c 'from pathlib import Path; import site; p=Path(site.getsitepackages()[0])/"cymysql.py"; p.write_text("from pymysql import *\nfrom pymysql import connect\n")'; \
    python -c 'from pathlib import Path; p=Path("/usr/local/shadowsocks/shadowsocks/lru_cache.py"); s=p.read_text(); s=s.replace("import collections\n","try:\n    from collections.abc import MutableMapping\nexcept ImportError:\n    from collections import MutableMapping\n"); s=s.replace("class LRUCache(collections.MutableMapping):","class LRUCache(MutableMapping):"); p.write_text(s)'

COPY docker-entrypoint.sh /usr/local/bin/kcloud-entrypoint
RUN chmod +x /usr/local/bin/kcloud-entrypoint; \
    mkdir -p /data /var/log/kcloud

WORKDIR /usr/local/shadowsocks
ENTRYPOINT ["kcloud-entrypoint"]
CMD ["run"]
