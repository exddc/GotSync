FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:0.7.18 /uv /uvx /bin/
WORKDIR /app
ENV UV_PROJECT_ENVIRONMENT=/opt/gotsync/python \
    PYTHONDONTWRITEBYTECODE=1
RUN groupadd --gid 10001 gotsync && useradd --uid 10001 --gid gotsync --no-create-home gotsync
COPY pyproject.toml uv.lock LICENSE ./
COPY gotsync_server ./gotsync_server
RUN uv sync --locked --no-dev --no-editable --no-cache && mkdir /data && chown gotsync:gotsync /data
ENV PATH="/opt/gotsync/python/bin:$PATH"
USER gotsync:gotsync
VOLUME ["/data"]
EXPOSE 8765 8767
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8766/readyz', timeout=3)" || exit 1
ENTRYPOINT ["gotsync-server"]
CMD ["--host", "0.0.0.0", "--mailbox-host", "0.0.0.0", "--allow-insecure-non-loopback", "--mailbox-database", "/data/mailbox.sqlite3"]
