# Wraps every request to drive the MartenProfileLog tracer (see profile_log.cr).
# Registered at the very front of the middleware stack (config/settings/base.cr)
# so the recorded total includes the time spent in every inner middleware
# (cache-control, sessions, auth, etc.).
#
# When PROFILE is unset this is a near-zero-cost passthrough: one branch + a
# Time.instant read isn't worth gating away.
class MartenProfileLog::Middleware < Marten::Middleware
  def call(request : Marten::HTTP::Request, get_response : Proc(Marten::HTTP::Response)) : Marten::HTTP::Response
    return get_response.call unless MartenProfileLog.enabled?

    MartenProfileLog.start
    started = Time.instant
    response : Marten::HTTP::Response? = nil
    begin
      response = get_response.call
      response
    ensure
      total_ms = (Time.instant - started).total_milliseconds
      status = response.try(&.status.to_i32) || 0
      MartenProfileLog.finish(request, status, total_ms)
    end
  end
end
