# Lightweight per-request tracing, gated on the PROFILE=1 environment variable
# so it costs nothing when unset (the `enabled?` flag is read once at boot; each
# checkpoint also short-circuits if disabled).
#
# This is the diagnostic that proved the PG pool sizing in config/settings/base.cr:
# a 30-VU bench showed the heavy-tail outliers (~1100ms) coincided with
# `pool_wait_max ≈ 1000ms` on a single db.open call — the cost of a fresh
# TLS connection over a network hop. Pre-warming the pool moved that cost to boot.
#
# Usage from a handler:
#
#   MartenProfileLog.checkpoint("some_query") do
#     SomeModel.filter(...).to_a
#   end
#
# The middleware (middleware.cr, wired into the stack in
# config/settings/base.cr) calls `MartenProfileLog.start` on request entry and
# `MartenProfileLog.finish` on exit; finish emits one log line per request with the
# total wall time plus every recorded checkpoint and PG pool tally:
#
#   req path=/ method=GET status=200 total=87.45ms some_query=28.97ms \
#     db_calls=8 pool_wait_total=0.03ms pool_wait_max=0.0ms query_exec_total=85.10ms
#
# The trace is held in class-level Hashes keyed by `Fiber.current.object_id` so
# concurrent requests on different fibers don't clobber each other (Crystal's
# HTTP server uses one fiber per request).
module MartenProfileLog
  alias Checkpoint = NamedTuple(label: String, ms: Float64)

  # Cached at boot so the hot path is a constant load instead of an ENV lookup
  # per checkpoint. Toggling PROFILE requires a server restart — acceptable for
  # an introspection tool.
  ENABLED = ENV["PROFILE"]? == "1"

  @@traces = {} of UInt64 => Array(Checkpoint)

  # Per-fiber tally of `Marten::DB::Connection::Base#open` calls, fed by
  # `pool_patch.cr`. Tracks total + max pool-wait + total query-exec,
  # separated so a slow request can be classified as pool-saturation vs
  # slow-query vs render-bound at a glance.
  record PoolTally,
    calls : Int32 = 0,
    wait_total_ms : Float64 = 0.0,
    wait_max_ms : Float64 = 0.0,
    exec_total_ms : Float64 = 0.0

  @@pool_tallies = {} of UInt64 => PoolTally

  def self.enabled? : Bool
    ENABLED
  end

  # Called by the middleware at request entry.
  def self.start : Nil
    return unless ENABLED
    fiber_id = Fiber.current.object_id
    @@traces[fiber_id] = [] of Checkpoint
    @@pool_tallies[fiber_id] = PoolTally.new
  end

  # Record the wall time of a code block under `label`. Returns whatever the
  # block returns; no-op (just yields) when PROFILE is unset.
  def self.checkpoint(label : String, &)
    return yield unless ENABLED
    started = Time.instant
    begin
      result = yield
    ensure
      ms = (Time.instant - started).total_milliseconds
      trace = @@traces[Fiber.current.object_id]?
      trace << {label: label, ms: ms} if trace
    end
    result
  end

  # Called from the connection-open patch (pool_patch.cr) for each
  # db connection acquired during a request. wait_ms is the time spent waiting
  # for a pool slot; exec_ms is the time the SQL block ran.
  def self.record_pool_call(wait_ms : Float64, exec_ms : Float64) : Nil
    return unless ENABLED
    fiber_id = Fiber.current.object_id
    tally = @@pool_tallies[fiber_id]?
    return if tally.nil?
    @@pool_tallies[fiber_id] = PoolTally.new(
      calls: tally.calls + 1,
      wait_total_ms: tally.wait_total_ms + wait_ms,
      wait_max_ms: wait_ms > tally.wait_max_ms ? wait_ms : tally.wait_max_ms,
      exec_total_ms: tally.exec_total_ms + exec_ms,
    )
  end

  # Called by the middleware at request exit. Logs one summary line and discards
  # the per-fiber trace. Safe to call when no trace was started.
  def self.finish(request : Marten::HTTP::Request, status : Int32, total_ms : Float64) : Nil
    return unless ENABLED
    fiber_id = Fiber.current.object_id
    checkpoints = @@traces.delete(fiber_id)
    tally = @@pool_tallies.delete(fiber_id)
    breakdown = checkpoints ? checkpoints.map { |c| "#{c[:label]}=#{c[:ms].round(2)}ms" }.join(" ") : ""
    pool = tally ? (
      "db_calls=#{tally.calls} " \
      "pool_wait_total=#{tally.wait_total_ms.round(2)}ms " \
      "pool_wait_max=#{tally.wait_max_ms.round(2)}ms " \
      "query_exec_total=#{tally.exec_total_ms.round(2)}ms"
    ) : ""
    Log.info {
      "req path=#{request.path} method=#{request.method} status=#{status} " \
      "total=#{total_ms.round(2)}ms #{breakdown} #{pool}".strip.gsub(/ +/, " ")
    }
  end
end
