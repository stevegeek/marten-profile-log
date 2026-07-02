# Splits Marten's `Connection::Base#open` into two timings:
#
#   pool_wait  : time spent inside `using_connection` *before* the application
#                block runs — i.e. waiting for a free connection from the
#                crystal-db pool.
#   query_exec : time inside the application block (driver round-trip + result-
#                set hydration).
#
# A call made inside an existing transaction skips the pool checkout (reuses the
# transaction's connection); its wait is recorded as 0 and everything is folded
# into `query_exec`.
#
# Each call appends `(wait_ms, exec_ms)` to a per-fiber tally that MartenProfileLog
# dumps as part of the request's finish line, e.g.:
#
#   pool_wait_total=423.1ms pool_wait_max=210.4ms db_calls=6 query_exec_total=58.2ms
#
# That tells us at a glance whether the un-instrumented gap in a slow request is
# sitting in pool wait (connection saturation) vs render or other CPU work.
#
# Runtime-gated against `MartenProfileLog.enabled?` so a non-PROFILE build only pays a
# single branch per db.open call.
class Marten::DB::Connection::Base
  def open(&)
    if MartenProfileLog.enabled?
      open_instrumented { |c| yield c }
    else
      open_original { |c| yield c }
    end
  end

  # open_original mirrors Marten::DB::Connection::Base#open verbatim (src/marten/db/connection/base.cr) — keep in sync when bumping the marten pin.
  private def open_original(&)
    if (trx = current_transaction).nil?
      using_connection { |conn| yield conn }
    else
      yield trx.connection
    end
  end

  private def open_instrumented(&)
    if (trx = current_transaction).nil?
      wait_start = Time.instant
      using_connection do |conn|
        wait_ms = (Time.instant - wait_start).total_milliseconds
        exec_start = Time.instant
        begin
          yield conn
        ensure
          exec_ms = (Time.instant - exec_start).total_milliseconds
          MartenProfileLog.record_pool_call(wait_ms, exec_ms)
        end
      end
    else
      exec_start = Time.instant
      begin
        yield trx.connection
      ensure
        exec_ms = (Time.instant - exec_start).total_milliseconds
        MartenProfileLog.record_pool_call(0.0, exec_ms)
      end
    end
  end
end
