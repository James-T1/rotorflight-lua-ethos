local MSP_SET_RTC = 246

local timeIsSet = false
local lastRunTS = 0
local INTERVAL = 0.5

local function processMspReply(cmd,rx_buf)
    if cmd == MSP_SET_RTC then
        timeIsSet = true
    end
end

local function setRtc()
    if lastRunTS == 0 or lastRunTS + INTERVAL < os.clock() then
        -- only send datetime one time after telemetry connection became available
        -- or when connection is restored after e.g. lipo refresh
        local values = {}
        if apiVersion >= 1.041 then
            -- format: seconds after the epoch (32) / milliseconds (16)
            local now = getRtcTime()

            for i = 1, 4 do
                values[i] = now&0xFF
                now = now>>8
            end

            values[5] = 0 -- we don't have milliseconds
            values[6] = 0
        else
            -- format: year (16) / month (8) / day (8) / hour (8) / min (8) / sec (8)
            local now = getDateTime()
            local year = now.year

            values[1] = year&0xFF
            year = year>>8
            values[2] = year&0xFF
            values[3] = now.mon
            values[4] = now.day
            values[5] = now.hour
            values[6] = now.min
            values[7] = now.sec
        end

        protocol.mspWrite(MSP_SET_RTC, values)
        lastRunTS = os.clock()
    end

    mspProcessTxQ()
    processMspReply(mspPollReply())

    return timeIsSet
end

return { f = setRtc, t = "" }
