FROM elixir:1.17-slim AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config/ config/
COPY lib/ lib/
COPY priv/ priv/
COPY assets/ assets/

RUN mix assets.deploy
RUN mix compile
RUN mix release

# --- Runtime ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libncurses6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/babel ./

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD bash -c 'echo > /dev/tcp/localhost/8787' || exit 1

CMD ["./bin/babel", "start"]
