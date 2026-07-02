# marten-profile-log

PROFILE=1-gated per-request tracer for [Marten](https://martenframework.com/) that separates PG pool-wait from query-exec time.

Inert passthrough when `PROFILE` is unset — safe to ship to production and toggle on-demand.

Production-proven on the Writebook Marten deploy (see deploy notes).

## Install

Add to `shard.yml`:

```yaml
dependencies:
  marten_profile_log:
    github: stevegeek/marten-profile-log
```

In your entry file:

```crystal
require "marten_profile_log"
```

## Wiring

**1. Register the middleware outermost** in `config/settings/base.cr` so it captures the full request time including all inner middleware:

```crystal
config.middleware = [
  MartenProfileLog::Middleware,
  Marten::Middleware::GZip,
  Marten::Middleware::Session,
  # ...
]
```

**2. Wrap hot handler sections** with named checkpoints:

```crystal
MartenProfileLog.checkpoint("load_posts") do
  Post.filter(published: true).order("-created_at").to_a
end
```

**3. Toggle with `PROFILE=1`** — restart required (flag is cached at boot):

```
PROFILE=1 ./bin/server
```

## Example log line

```
req path=/ method=GET status=200 total=87.45ms load_posts=28.97ms db_calls=8 pool_wait_total=0.03ms pool_wait_max=0.0ms query_exec_total=85.10ms
```

The split between `pool_wait_*` and `query_exec_total` lets you classify slow requests as connection-saturation vs slow-query vs render-bound at a glance.

## Provenance

Extracted from the Writebook Marten port. The pool-wait timing was the diagnostic that identified heavy-tail outliers (~1100ms) coinciding with `pool_wait_max ≈ 1000ms` on cold TLS connections — pre-warming the pool eliminated them. See deploy notes.
