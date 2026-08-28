# SPDX-License-Identifier: MIT

module JackBaboon

import Base: Semaphore, release, acquire
import UUIDs: uuid4, UUID

export
    Executor,
    #Base.close,
    #Base.isopen,
    iscrashed,
    isclosed,
    execute!,
    submit!,

    # CancelToken
    iscancelrequested,

    #Handle
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
    JobCancelledError


include("cancel_token.jl")
include("state_machines.jl")
include("tracing.jl")
include("handles.jl")
include("jobs.jl")
include("executors.jl")


end  # of module JackBaboon
