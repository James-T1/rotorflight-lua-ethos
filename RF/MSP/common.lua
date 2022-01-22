-- Protocol version
local MSP_VERSION = 1<<5
local MSP_STARTFLAG = 1<<4

-- Sequence number for next MSP packet
local mspSeq = 0
local mspRemoteSeq = 0
local mspRxBuf = {}
local mspRxCRC = 0
local mspRxReq = 0
local mspStarted = false
local mspLastReq = 0
local mspTxBuf = {}
local mspTxIdx = 1
local mspTxCRC = 0

function mspProcessTxQ()
    if (#(mspTxBuf) == 0) then
        return false
    end
    -- if not sensor:idle() then  -- was protocol.push() -- maybe sensor:idle()  here??
        -- print("Sensor not idle... waiting to send cmd: "..tostring(mspLastReq))
        -- return true
    -- end
    print("Sending mspTxBuf size "..tostring(#mspTxBuf).." at Idx "..tostring(mspTxIdx).." for cmd: "..tostring(mspLastReq))
    local payload = {}
    payload[1] = mspSeq + MSP_VERSION
    mspSeq = (mspSeq + 1)&(0x0F)
    if mspTxIdx == 1 then
        -- start flag
        payload[1] = payload[1] + MSP_STARTFLAG
    end
    local i = 2
    while (i <= protocol.maxTxBufferSize) and (mspTxIdx <= #mspTxBuf) do
        payload[i] = mspTxBuf[mspTxIdx]
        mspTxIdx = mspTxIdx + 1
        mspTxCRC = mspTxCRC~payload[i]
        i = i + 1
    end
    if i <= protocol.maxTxBufferSize then
        payload[i] = mspTxCRC
        i = i + 1
      -- zero fill
        while i <= protocol.maxTxBufferSize do
            payload[i] = 0
            i = i + 1
        end
        protocol.mspSend(payload)
        mspTxBuf = {}
        mspTxIdx = 1
        mspTxCRC = 0
        return false
    end
    protocol.mspSend(payload)
    return true
end

function mspSendRequest(cmd, payload)
    -- busy
    if ((#(mspTxBuf) ~= 0) or (not cmd)) then
        print("Existing mspTxBuf is still being sent, failed send of cmd: "..tostring(cmd))
        return nil
    end
    mspTxBuf[1] = #(payload)
    mspTxBuf[2] = cmd&(0xFF)  -- MSP command
    for i=1,#(payload) do
        mspTxBuf[i+2] = payload[i]&(0xFF)
    end
    mspLastReq = cmd
    return mspProcessTxQ()
end

function mspReceivedReply(payload)
    --print("Starting mspReceivedReply")
    local idx      = 1
    local head     = payload[idx]
    local err_flag = (head&0x20) ~= 0
    idx = idx + 1
    if err_flag then
        -- error flag set
		print("  mspReceivedReply:  msp error flag set")
        mspStarted = false
        return nil
    end
    local start = (head&0x10) ~= 0
    local seq   = head&0x0F
    --print(" msp sequence #:  "..string.format("%u",seq))
    if start then
        -- start flag set
        mspRxBuf = {}
        mspRxSize = payload[idx]
        --print("  mspRxSize:  "..string.format("%u",mspRxSize).." bytes")
        mspRxCRC  = mspRxSize~mspLastReq
        --print("  Beginning CRC calculation with previous command:  "..tostring(mspLastReq))
        mspRxReq  = mspLastReq
        idx = idx + 1
        mspStarted = true
    elseif not mspStarted then
		print("  mspReceivedReply: missing Start flag")
        return nil
    elseif (mspRemoteSeq + 1)&(0x0F) ~= seq then
		print("  mspReceivedReply: msp packet sequence # incorrect")
        mspStarted = false
        return nil
    end
    while (idx <= protocol.maxRxBufferSize) and (#mspRxBuf < mspRxSize) do  --ok
        mspRxBuf[#mspRxBuf + 1] = payload[idx]
        mspRxCRC = mspRxCRC~payload[idx]
        idx = idx + 1
    end
    if idx > protocol.maxRxBufferSize then
		--print("  mspReceivedReply:  payload continues into next frame.")
        -- Store the last sequence number so we can start there on the next continuation payload
        mspRemoteSeq = seq
        return true
    end
    mspStarted = false
    -- check CRC
    if mspRxCRC ~= payload[idx] then
		print("  mspReceivedReply:  payload checksum incorrect, message failed!")
        --print("    Calculated mspRxCRC:  0x"..string.format("%X", mspRxCRC))
        --print("    CRC from payload:     0x"..string.format("%X", payload[idx]))
        return nil
    end
    print("  Successfully processed mspRxBuf and verified checksum.")
    return mspRxBuf
end

function mspPollReply()
    while true do
        local ret = protocol.mspPoll()
        if type(ret) == "table" then
            --print("mspPoll properly returned table.")
            mspLastReq = 0
            return mspRxReq, ret
        else
            break
        end
    end
    -- print("mspPollReply returned nil")
    return nil
end
