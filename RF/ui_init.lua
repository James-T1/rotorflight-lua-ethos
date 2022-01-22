local apiVersionReceived = false
local getApiVersion, f
local returnTable = { f = nil, t = "" }

local function init()
    if getRSSI() == 0 then
        returnTable.t = "Waiting for connection"
    elseif not apiVersionReceived then
        getApiVersion = getApiVersion or assert(loadfile("/scripts/RF/api_version.lua"))()
        returnTable.t = getApiVersion.t
        apiVersionReceived = getApiVersion.f()
        if apiVersionReceived then
            getApiVersion = nil
            collectgarbage()
        end
    else
        return true
    end
    return apiVersionReceived
end

returnTable.f = init

return returnTable
