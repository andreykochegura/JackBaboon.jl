# SPDX-License-Identifier: MIT

mutable struct Atomic{T}
    @atomic x::T
end

const JOB_DBG_TRACE_GLOBAL_SEQUENCE = Atomic{UInt64}(UInt64(0))

next_job_trace_global_sequence() = @atomic JOB_DBG_TRACE_GLOBAL_SEQUENCE.x += 1

const JOB_DBG_TRACE_ENABLED = Atomic{Bool}(false)

enable_job_global_dbg_tracing() = @atomic JOB_DBG_TRACE_ENABLED.x = true

disable_job_global_dbg_tracing() = @atomic JOB_DBG_TRACE_ENABLED.x = false

is_job_global_dbg_tracing_on() = @atomic JOB_DBG_TRACE_ENABLED.x
