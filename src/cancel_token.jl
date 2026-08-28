# SPDX-License-Identifier: MIT

mutable struct CancelToken
    @atomic request :: Bool

    CancelToken() = new(false)
end


"""
    iscancelrequested(token::CancelToken)::Bool

Return `true` if stop has been requested for the job.

# Examples
```julia-repl
julia> executor = Executor();
julia> handle = submit!(executor) do cancel_token
        while ! iscancelrequested(cancel_token)
            do_work()
            yield()
        end
        nothing
    end;
julia> stop!(handle);
julia> wait(handle)
julia> iscanceled(handle)
true
```
"""
iscancelrequested(token::CancelToken)::Bool = @atomic token.request
