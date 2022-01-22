local LCD_W = 784
local LCD_H = 406

local supportedRadios =
{
    ["784x406"] = 
    {
        msp = {
            template = "/scripts/RF/TEMPLATES/784x406.lua",
            highRes = true,
            -- MenuBox = { x=120, y=100, w=200, x_offset=68, h_line=20, h_offset=6 },
            -- SaveBox = { x=120, y=100, w=180, x_offset=12, h=60, h_offset=12 },
            -- NoTelem = { 70, 55, "No Telemetry", BLINK },
            MenuBox = { x= (LCD_W -200)/2, y=LCD_H/2, w=200, x_offset=68, h_line=20, h_offset=6 },
            SaveBox = { x= (LCD_W -200)/2, y=LCD_H/2, w=180, x_offset=12, h=60, h_offset=12 },
            NoTelem = { LCD_W/2 - 50, LCD_H - 28, "No Telemetry", BLINK },
            textSize = 0,
            yMinLimit = 35,
            yMaxLimit = 361,
        },
    },
}

local w, h = lcd.getWindowSize()
local resolution = w.."x"..h
local radio = assert(supportedRadios[resolution], resolution.." not supported")
print(radio)

return radio
