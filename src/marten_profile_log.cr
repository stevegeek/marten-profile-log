require "marten"

# marten-profile-log — PROFILE=1-gated per-request tracer for Marten that
# separates PG pool-wait from query-exec time. Inert passthrough when unset.
# Production-proven on a Writebook Marten deploy.
module MartenProfileLog
  VERSION = "0.1.0"
end

require "./marten_profile_log/profile_log"
require "./marten_profile_log/pool_patch"
require "./marten_profile_log/middleware"
