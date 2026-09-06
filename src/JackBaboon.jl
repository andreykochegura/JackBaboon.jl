# SPDX-License-Identifier: MIT

module JackBaboon

import Base: Semaphore, release, acquire
import UUIDs: uuid4, UUID

export
    Executor,
    iscrashed,
    isclosed,
    execute!,
    submit!,
    iscancelrequested,
    stop!,
    isqueued,
    ispending,
    isrunning,
    isfailed,
    iscompleted,
    isstopping,
    isstopped,
    iscanceled,
    isfinal,
    ExecutorInternalError,
    ExecutorClosedError,
    ExecutorRejectedError,
    ExecutorJobCancelledError


include("cancel_token.jl")
include("state_machines.jl")
include("tracing.jl")
include("handles.jl")
include("jobs.jl")
include("executors.jl")


end  # of module JackBaboon
