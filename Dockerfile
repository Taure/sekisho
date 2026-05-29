# Build the prod release as a self-contained OCI image (deploy anywhere).
FROM erlang:29 AS build
WORKDIR /src
COPY rebar.config rebar.lock ./
RUN rebar3 as prod compile
COPY src ./src
COPY config ./config
COPY priv ./priv
RUN rebar3 as prod release

# Self-contained runtime (the release bundles ERTS). trixie-slim matches
# erlang:29's Debian release so the bundled ERTS finds a compatible glibc.
FROM debian:trixie-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl libncurses6 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/_build/prod/rel/sekisho ./
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]
