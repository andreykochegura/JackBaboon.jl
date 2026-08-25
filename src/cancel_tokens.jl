# SPDX-License-Identifier: MIT

mutable struct CancelToken
    @atomic flag :: Bool

    CancelToken() = new(false)
end

iscanceled(token::CancelToken)::Bool =
    @atomic token.flag 

function cancel!(token::CancelToken)::CancelToken
    @atomic token.flag = true
    return token
end
