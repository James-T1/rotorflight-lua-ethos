local supportedProtocols =
{
    smartPort =
    {
        mspTransport    = "/scripts/RF/MSP/sp.lua",
        push            = sportTelemetryPush,
        maxTxBufferSize = 6,
        maxRxBufferSize = 6,
        saveMaxRetries  = 30,      -- originally 2
        saveTimeout     = 2.0,     -- in seconds, originally 5
        pageReqTimeout  = 2.0,     -- in seconds, originally 0.8  (then 1.5)
    }
}

return supportedProtocols.smartPort
