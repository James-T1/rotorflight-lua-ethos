-- RotorFlight + ETHOS LUA configuration

--local toolName = "TNS|Rotorflight conf|TNE"
--chdir("/SCRIPTS/RF")

local uiStatus =
{
    init     = 1,
    mainMenu = 2,
    pages    = 3,
    confirm  = 4,
}

local pageStatus =
{
    display = 1,
    editing = 2,
    saving  = 3,
    eepromWrite = 4,
    rebooting = 5,
}

local uiMsp =
{
    reboot = 68,
    eepromWrite = 250,
}

local uiState = uiStatus.init
local prevUiState
local pageState = pageStatus.display
-- local requestTimeout = 1.5   -- in seconds (originally 0.8)
local currentPage = 1
local currentField = 1
local saveTS = 0
local saveRetries = 0
local popupMenuActive = 1
local pageScrollY = 0
local mainMenuScrollY = 0
local rssiValue = 0
local saveTimeout, saveMaxRetries, PageFiles, Page, init, popupMenu, requestTimeout, rssiSensor

-- New variables for Ethos version
local screenTitle = nil
local lastEvent = nil
lcdNeedsInvalidate = false
local sportDelayCounter = 1

--- Virtual key translations from Ethos to OpenTX
local EVT_VIRTUAL_ENTER = 32          -- pgup/dn if break without long/repeat
local EVT_VIRTUAL_ENTER_LONG = 129    -- pgup/dn long
local EVT_VIRTUAL_EXIT = 97           -- enter button on right side will be our exit since break isn't working
-- These two incPopup/MainMenu() selections up and down and page fields (incFields())
  -- Mdl/Rtn  (up/down) to change values
local EVT_VIRTUAL_PREV = 99   -- on rtn & rtn/repeat  (make sure to return true for capture)
-- local EVT_VIRTUAL_PREV_REPT = 1337  -- unused
local EVT_VIRTUAL_NEXT = 98   -- on disp/long/repeat  on mdl & mdl long/repeat
-- local EVT_VIRTUAL_PREV_REPT = 1337  -- unused
-- These 4 incValue() if a page is being edited
  -- Disp/Sys  (left/right) to move fields
local EVT_VIRTUAL_INC = 100                 -- on disp/long/repeat
-- local EVT_VIRTUAL_INC_REPT = 1337           -- unused
local EVT_VIRTUAL_DEC = 101                 -- on sys/long/repeat
-- local EVT_VIRTUAL_DEC_REPT = 1337           -- unused
-- These two incPage() ... not necessary.
-- local EVT_VIRTUAL_PREV_PAGE = 1337
-- local EVT_VIRTUAL_NEXT_PAGE = 1337

protocol = nil
radio = nil
sensor = nil

local function saveSettings()
    if Page.values then
        local payload = Page.values
        if Page.preSave then
            payload = Page.preSave(Page)
        end
        saveTS = os.clock()
        if pageState == pageStatus.saving then
            saveRetries = saveRetries + 1
        else
            pageState = pageStatus.saving
            saveRetries = 0
            print("Attempting to write page values...")
        end
        protocol.mspWrite(Page.write, payload)
    end
end

local function eepromWrite()
    saveTS = os.clock()
    if pageState == pageStatus.eepromWrite then
        saveRetries = saveRetries + 1
    else
        pageState = pageStatus.eepromWrite
        saveRetries = 0
        print("Attempting to write to eeprom...")
    end
    protocol.mspRead(uiMsp.eepromWrite)
end

local function rebootFc()
    -- Only sent once.  I think a response may come back from FC if successful?
    -- May want to either check for that and repeat if not, or check for loss of telemetry to confirm, etc.
    -- TODO: Implement an auto-retry?  Right now if the command gets lost then there's just no reboot and no notice.
    print("Attempting to reboot the FC (one shot)...")
    saveTS = os.clock()
    pageState = pageStatus.rebooting
    protocol.mspRead(uiMsp.reboot)
    -- https://github.com/rotorflight/rotorflight-firmware/blob/9a5b86d915df557ff320f30f1376cb8ce9377157/src/main/msp/msp.c#L1853
end

local function invalidatePages()
    Page = nil
    pageState = pageStatus.display
    saveTS = 0
    collectgarbage()
    lcdNeedsInvalidate = true
end

local function confirm(page)
    prevUiState = uiState
    uiState = uiStatus.confirm
    invalidatePages()
    currentField = 1
    Page = assert(loadfile(page))()
    lcdNeedsInvalidate = true
    collectgarbage()
end

-- Run lcd.invalidate() if anything actionable comes back from it.
local function processMspReply(cmd,rx_buf)
    if not Page or not rx_buf then
    elseif cmd == Page.write then
        -- check if this page requires writing to eeprom to save (most do)
        if Page.eepromWrite then
            -- don't write again if we're already responding to earlier page.write()s
            if pageState ~= pageStatus.eepromWrite then
                eepromWrite()
            end
        elseif pageState ~= pageStatus.eepromWrite then
            -- If we're not already trying to write to eeprom from a previous save, then we're done.
            invalidatePages()
        end
        lcdNeedsInvalidate = true
    elseif cmd == uiMsp.eepromWrite then
        if Page.reboot then
            rebootFc()
        end
        invalidatePages()
    elseif (cmd == Page.read) and (#rx_buf > 0) then
        --print("processMspReply:  Page.read and non-zero rx_buf")
        Page.values = rx_buf
        if Page.postRead then
            Page.postRead(Page)
        end
        for i=1,#Page.fields do
            if #Page.values >= Page.minBytes then
                local f = Page.fields[i]
                if f.vals then
                    f.value = 0
                    for idx=1, #f.vals do
                        local raw_val = Page.values[f.vals[idx]] or 0
                        raw_val = raw_val<<((idx-1)*8)
                        f.value = f.value|raw_val
                    end
                    f.value = f.value/(f.scale or 1)
                end
            end
        end
        if Page.postLoad then
            Page.postLoad(Page)
        end
        lcdNeedsInvalidate = true
    end
end

local function requestPage()
    if Page.read and ((not Page.reqTS) or (Page.reqTS + requestTimeout <= os.clock())) then
        --print("Trying requestPage()")
        Page.reqTS = os.clock()
        protocol.mspRead(Page.read)
    end
end

local function createPopupMenu()
    popupMenuActive = 1
    popupMenu = {}
    if uiState == uiStatus.pages then
        popupMenu[#popupMenu + 1] = { t = "save page", f = saveSettings }
        popupMenu[#popupMenu + 1] = { t = "reload", f = invalidatePages }
    end
    popupMenu[#popupMenu + 1] = { t = "reboot", f = rebootFc }
    popupMenu[#popupMenu + 1] = { t = "acc cal", f = function() confirm("/scripts/RF/CONFIRM/acc_cal.lua") end }
end

local function incMax(val, inc, base)
    return ((val + inc + base - 1) % base) + 1
end

function clipValue(val,min,max)
    if val < min then
        val = min
    elseif val > max then
        val = max
    end
    return val
end

-- local function incPage(inc)
    -- currentPage = incMax(currentPage, inc, #PageFiles)
    -- currentField = 1
    -- invalidatePages()
-- end

local function incField(inc)
    currentField = clipValue(currentField + inc, 1, #Page.fields)
end

local function incMainMenu(inc)
    currentPage = clipValue(currentPage + inc, 1, #PageFiles)
end

local function incPopupMenu(inc)
    popupMenuActive = clipValue(popupMenuActive + inc, 1, #popupMenu)
end

local function incValue(inc)
    local f = Page.fields[currentField]
    local scale = f.scale or 1
    local mult = f.mult or 1
    f.value = clipValue(f.value + inc*mult/scale, (f.min or 0)/scale, (f.max or 255)/scale)
    f.value = math.floor(f.value*scale/mult + 0.5)*mult/scale
    for idx=1, #f.vals do
        Page.values[f.vals[idx]] = math.floor(f.value*scale + 0.5)>>((idx-1)*8)
    end
    if f.upd and Page.values then
        f.upd(Page)
    end
end

-- OpenTX <-> Ethos mapping functions

function sportTelemetryPop()
  -- Pops a received SPORT packet from the queue. Please note that only packets using a data ID within 0x5000 to 0x50FF (frame ID == 0x10), as well as packets with a frame ID equal 0x32 (regardless of the data ID) will be passed to the LUA telemetry receive queue.
  local frame = sensor:popFrame()
  if frame == nil then
    return nil, nil, nil, nil
  end
  -- physId = physical / remote sensor Id (aka sensorId)
  --   0x00 for FPORT, 0x1B for SmartPort
  -- primId = frame ID  (should be 0x32 for reply frames)
  -- appId = data Id
  return frame:physId(), frame:primId(), frame:appId(), frame:value()
end

function sportTelemetryPush(sensorId, frameId, dataId, value)
    -- OpenTX:
        -- When called without parameters, it will only return the status of the output buffer without sending anything.
        --   Equivalent in Ethos may be:   sensor:idle() ???
        -- @param sensorId  physical sensor ID
        -- @param frameId   frame ID
        -- @param dataId    data ID
        -- @param value     value
        -- @retval boolean  data queued in output buffer or not.
        -- @retval nil      incorrect telemetry protocol.  (added in 2.3.4)
  return sensor:pushFrame({physId=sensorId, primId=frameId, appId=dataId, value=value})
end

function getRSSI()
  -- local rssiSensor = system.getSource("RSSI")
  if rssiSensor ~= nil then
    return rssiSensor:value()
  end
  -- return 0 if no telemetry signal to match OpenTX
  return 0
end


---
--- ETHOS system tool functions
---

local translations = {en="RF"}

local function name(widget)
  local locale = system.getLocale()
  return translations[locale] or translations["en"]
end

-- CREATE:  Called once each time the system widget is opened by the user.
local function create()
  sensor = sport.getSensor({primId=0x32})
  rssiSensor = system.getSource("RSSI")
  --sensor:idle(false)
  
  protocol = assert(loadfile("/scripts/RF/protocols.lua"))()
  radio = assert(loadfile("/scripts/RF/radios.lua"))().msp
  assert(loadfile(protocol.mspTransport))()
  assert(loadfile("/scripts/RF/MSP/common.lua"))()
  
  -- Initial var setting
  saveTimeout = protocol.saveTimeout
  saveMaxRetries = protocol.saveMaxRetries
  requestTimeout = protocol.pageReqTimeout
  screenTitle = "Rotorflight Config"
  popupMenu = nil
  lastEvent = nil
  apiVersion = 0
  
  return {}
end


-- WAKEUP:  Called every ~30-50ms by the main Ethos software loop
local function wakeup(widget)
  -- print(os.clock())
  
    if (radio == nil or protocol == nil) then
        print("Error:  wakeup() called but create must have failed!")
        return 0
    end
    
    processMspReply(mspPollReply())
    
    -- Only run on loops 1 and 4
    if (sportDelayCounter ~= 1) and (sportDelayCounter ~= 4) then
        sportDelayCounter = sportDelayCounter + 1
        -- Reset on loop 6
        if (sportDelayCounter == 6) then
            sportDelayCounter = 1
        end
        return 0
    end
        
  -- run_ui(event)
    if popupMenu then
        if lastEvent == EVT_VIRTUAL_EXIT then
            popupMenu = nil
            lcdNeedsInvalidate = true
        elseif lastEvent == EVT_VIRTUAL_PREV then
            incPopupMenu(-1)
            lcdNeedsInvalidate = true
        elseif lastEvent == EVT_VIRTUAL_NEXT then
            incPopupMenu(1)
            lcdNeedsInvalidate = true
        elseif lastEvent == EVT_VIRTUAL_ENTER then
            popupMenu[popupMenuActive].f()
            popupMenu = nil
            lcdNeedsInvalidate = true
        end
    elseif uiState == uiStatus.init then
        screenTitle = "Rotorflight Config"
        local prevInit
        if init ~= nil then
            prevInit = init.t
        end
        init = init or assert(loadfile("/scripts/RF/ui_init.lua"))()
        if prevInit ~= init.t then
            lcd.invalidate()
        end
        if not init.f() then
            -- waiting on api version to finish successfully.
            lastEvent = nil
            return 0
        end
        init = nil
        PageFiles = assert(loadfile("/scripts/RF/pages.lua"))()
        invalidatePages()
        uiState = prevUiState or uiStatus.mainMenu
        prevUiState = nil
    elseif uiState == uiStatus.mainMenu then
        screenTitle = "Rotorflight Config"
        if lastEvent == EVT_VIRTUAL_EXIT then
			lastEvent = nil
			lcd.invalidate()
            return 2
        elseif lastEvent == EVT_VIRTUAL_NEXT then
            incMainMenu(1)
            lcdNeedsInvalidate = true
        elseif lastEvent == EVT_VIRTUAL_PREV then
            incMainMenu(-1)
            lcdNeedsInvalidate = true
        elseif lastEvent == EVT_VIRTUAL_ENTER then
            uiState = uiStatus.pages
            pageState = pageStatus.display  -- added in case we reboot from popup over main menu
            lcdNeedsInvalidate = true
        elseif lastEvent == EVT_VIRTUAL_ENTER_LONG then
            print("Popup from main menu")
            createPopupMenu()
            lcdNeedsInvalidate = true
        end
    elseif uiState == uiStatus.pages then
        if pageState == pageStatus.saving then
            if (saveTS + saveTimeout) < os.clock() then
                if saveRetries < saveMaxRetries then
                    saveSettings()
                    lcdNeedsInvalidate = true
                else
                    print("Failed to write page values!")
                    invalidatePages()
                end
                -- drop through to processMspReply to send MSP_SET and see if we've received a response to this yet.
            end
        elseif pageState == pageStatus.eepromWrite then
            if (saveTS + saveTimeout) < os.clock() then
                if saveRetries < saveMaxRetries then
                    eepromWrite()
                    lcdNeedsInvalidate = true
                else
                    print("Failed to write to eeprom!")
                    invalidatePages()
                end
                -- drop through to processMspReply to send MSP_SET and see if we've received a response to this yet.
            end
        elseif pageState == pageStatus.rebooting then
            -- TODO:  Rebooting is only a one-try shot.  Would be nice if it retried automatically.
            if (saveTS + saveTimeout) < os.clock() then
                invalidatePages()
            end
            -- drop through to processMspReply to send MSP_SET and see if we've received a response to this yet.
        elseif pageState == pageStatus.display then
            -- if lastEvent == EVT_VIRTUAL_PREV_PAGE then
                -- incPage(-1)
                -- lcdNeedsInvalidate = true
            -- elseif lastEvent == EVT_VIRTUAL_NEXT_PAGE then
                -- incPage(1)
                -- lcdNeedsInvalidate = true
            --elseif lastEvent == EVT_VIRTUAL_PREV or lastEvent == EVT_VIRTUAL_PREV_REPT then
            if lastEvent == EVT_VIRTUAL_PREV then -- or lastEvent == EVT_VIRTUAL_PREV_REPT then
                incField(-1)
                lcdNeedsInvalidate = true
            elseif lastEvent == EVT_VIRTUAL_NEXT then -- or lastEvent == EVT_VIRTUAL_NEXT_REPT then
                incField(1)
                lcdNeedsInvalidate = true
            elseif lastEvent == EVT_VIRTUAL_ENTER then
                if Page then
                    local f = Page.fields[currentField]
                    if Page.values and f.vals and Page.values[f.vals[#f.vals]] and not f.ro then
                        pageState = pageStatus.editing
                        lcdNeedsInvalidate = true
                    end
                end
            elseif lastEvent == EVT_VIRTUAL_ENTER_LONG then
                print("Popup from page")
                createPopupMenu()
                lcdNeedsInvalidate = true
            elseif lastEvent == EVT_VIRTUAL_EXIT then
                invalidatePages()
                currentField = 1
                uiState = uiStatus.mainMenu
                lcd.invalidate()
				lastEvent = nil
                return 0
            end
        elseif pageState == pageStatus.editing then
            if ((lastEvent == EVT_VIRTUAL_EXIT) or (lastEvent == EVT_VIRTUAL_ENTER)) then
                if Page.fields[currentField].postEdit then
                    Page.fields[currentField].postEdit(Page)
                end
                pageState = pageStatus.display
				lcdNeedsInvalidate = true
            elseif lastEvent == EVT_VIRTUAL_INC then -- or lastEvent == EVT_VIRTUAL_INC_REPT then
                incValue(1)
				lcdNeedsInvalidate = true
            elseif lastEvent == EVT_VIRTUAL_DEC then -- or lastEvent == EVT_VIRTUAL_DEC_REPT then
                incValue(-1)
				lcdNeedsInvalidate = true
            end
        end
        if not Page then
            Page = assert(loadfile("/scripts/RF/PAGES/"..PageFiles[currentPage].script))()
            collectgarbage()
        end
        if not Page.values and pageState == pageStatus.display then
            requestPage()
        end
    elseif uiState == uiStatus.confirm then
        if lastEvent == EVT_VIRTUAL_ENTER then
            uiState = uiStatus.init
            init = Page.init
            invalidatePages()
        elseif lastEvent == EVT_VIRTUAL_EXIT then
            invalidatePages()
            uiState = prevUiState
            prevUiState = nil
        end
    end
  
  -- Process outgoing TX packets and check for incoming frames
  --  Should run every wakeup() cycle with a few exceptions where returns happen earlier
  if (sportDelayCounter == 1) then
    print(os.clock())
    mspProcessTxQ()
    sportDelayCounter = sportDelayCounter + 1
  elseif (sportDelayCounter == 4) then
    rssiValue = getRSSI()        
    if rssiValue == 0 then
        -- invalidatePages()
        lcdNeedsInvalidate = true
    end
    sportDelayCounter = sportDelayCounter + 1
  end
  
  if lastEvent ~= 96 then    -- if captured an initial pg up/dn (enter) press, then just leave it there for long press detect.
    lastEvent = nil          -- clear last detected key or touch event
  end
  
  if lcdNeedsInvalidate == true then
    lcdNeedsInvalidate = false
    lcd.invalidate()
  end
  
  return 0

end


-- EVENT:  Called for button presses, scroll events, touch events, etc.
local function event(widget, category, value, x, y)
  print("Event received:", category, value, x, y)
  if category == EVT_KEY then
    if value ==  97 then                  -- Enter pressed.  Using as exit for now since no break indication.  Ignore long/repeats/break.
        lastEvent = EVT_VIRTUAL_EXIT
        return true
    elseif (value ==  101 or value == 133 or value == 69) then   -- Sys pressed.
        lastEvent = EVT_VIRTUAL_DEC
        return true
    elseif (value ==  100 or value == 132 or value == 68) then   -- Disp pressed.
        lastEvent = EVT_VIRTUAL_INC
        return true
    elseif (value ==  99 or value == 131 or value == 67) then   -- Rtn pressed.
        lastEvent = EVT_VIRTUAL_NEXT
        return true
    elseif value == 35 then                                     -- Capture Rtn break to prevent exiting widget
        return true
    elseif (value ==  98 or value == 130 or value == 66) then   -- Mdl pressed.
        lastEvent = EVT_VIRTUAL_PREV
        return true
    elseif value == 96 then                         -- pg up/dn initial press - store to determine if short or long.
        lastEvent = 96
        return true    
    elseif (value == 32 and lastEvent == 96) then   -- pg up/dn break before long press is triggered
        lastEvent = EVT_VIRTUAL_ENTER
        return true
    elseif value == 128 then                        -- pg up/dn long press
        lastEvent = EVT_VIRTUAL_ENTER_LONG
        return true        
    end
  end
  
  return false
end

-- Paint() helpers:
local MENU_TITLE_BGCOLOR = lcd.RGB(55, 55, 55)  -- dark grey
local MENU_TITLE_COLOR = lcd.RGB(62, 145, 247)  -- light blue
local ITEM_TEXT_SELECTED = lcd.RGB(62, 145, 247)  -- selected in light blue
local ITEM_TEXT_NORMAL = lcd.RGB(200, 200, 200)  -- unselected text in light grey/white
local ITEM_TEXT_EDITING = lcd.RGB(255, 0, 0)     -- red text

local function drawScreen()
    local LCD_W, LCD_H = lcd.getWindowSize()
    if Page then
        local yMinLim = radio.yMinLimit
        local yMaxLim = radio.yMaxLimit
        local currentFieldY = Page.fields[currentField].y
        if currentFieldY <= Page.fields[1].y then
            pageScrollY = 0
        elseif currentFieldY - pageScrollY <= yMinLim then
            pageScrollY = currentFieldY - yMinLim
        elseif currentFieldY - pageScrollY >= yMaxLim then
            pageScrollY = currentFieldY - yMaxLim
        end
        for i=1,#Page.labels do
            local f = Page.labels[i]
            local y = f.y - pageScrollY
            if y >= 0 and y <= LCD_H then
                lcd.font(FONT_S_BOLD)
                lcd.color(ITEM_TEXT_NORMAL)
                lcd.drawText(f.x, y, f.t)
            end
        end
        local val = "---"
        for i=1,#Page.fields do
            local f = Page.fields[i]
            if f.value then
                if f.upd and Page.values then
                    f.upd(Page)
                end
                val = f.value
                if f.table and f.table[f.value] then
                    val = f.table[f.value]
                end
            end
            local y = f.y - pageScrollY
            if y >= 0 and y <= LCD_H then
                if f.t then
                    lcd.font(FONT_S)
                    lcd.color(ITEM_TEXT_NORMAL)
                    lcd.drawText(f.x, y, f.t)
                end
                if i == currentField then
                    if pageState == pageStatus.editing then
                        lcd.font(FONT_S_BOLD)
                        lcd.color(ITEM_TEXT_EDITING)
                    else
                        lcd.font(FONT_S)
                        lcd.color(ITEM_TEXT_SELECTED)
                    end
                else
                    lcd.font(FONT_S)
                    lcd.color(ITEM_TEXT_NORMAL)
                end
                strVal = ""
                if (type(val) == "string") then
                    strVal = val
                elseif (type(val) == "number") then
                    if math.floor(val) == val then
                        strVal = string.format("%i",val)
                    else
                        strVal = tostring(val)
                    end                    
                else
                    strVal = val
                end
                lcd.drawText(f.sp or f.x, y, strVal)
            end
        end
        screenTitle = "Rotorflight / "..Page.title
    end
end

-- PAINT:  Called when the screen or a portion of the screen is invalidated (timer, etc)
local function paint(widget)

    if (radio == nil or protocol == nil) then
        print("Error:  paint() called, but create must have failed!")
        return
    end
    
    local LCD_W, LCD_H = lcd.getWindowSize()
  
    -- drawPopupMenu() from ui.c
    if popupMenu then
        print("painting popupMenu")
        local x = radio.MenuBox.x
        local y = radio.MenuBox.y
        local w = radio.MenuBox.w
        local h_line = radio.MenuBox.h_line
        local h_offset = radio.MenuBox.h_offset
        local h = #popupMenu * h_line + h_offset*2

        lcd.color(MENU_TITLE_BGCOLOR)
        lcd.drawFilledRectangle(x,y,w,h)
        lcd.color(MENU_TITLE_COLOR)
        lcd.drawRectangle(x,y,w-1,h-1)
        lcd.color(MENU_TITLE_COLOR)
        lcd.font(FONT_S)
        lcd.drawText(x+h_line/2,y+h_offset,"Menu:")

        for i,e in ipairs(popupMenu) do
            lcd.color(ITEM_TEXT_NORMAL)
            if popupMenuActive == i then
                lcd.color(ITEM_TEXT_SELECTED)
            end
            lcd.drawText(x+radio.MenuBox.x_offset,y+(i-1)*h_line+h_offset,e.t)
        end
    end

    if uiState == uiStatus.init then
        print("painting uiState == uiStatus.init")
        lcd.color(ITEM_TEXT_EDITING)
        lcd.font(FONT_S)
        lcd.drawText(6, radio.yMinLimit, init.t)
    elseif uiState == uiStatus.mainMenu then
        print("painting uiState == uiStatus.mainMenu")
        local yMinLim = radio.yMinLimit
        local yMaxLim = radio.yMaxLimit
        local lineSpacing = 10
        if radio.highRes then
            lineSpacing = 25
        end
        local currentFieldY = (currentPage-1)*lineSpacing + yMinLim
        if currentFieldY <= yMinLim then
            mainMenuScrollY = 0
        elseif currentFieldY - mainMenuScrollY <= yMinLim then
            mainMenuScrollY = currentFieldY - yMinLim
        elseif currentFieldY - mainMenuScrollY >= yMaxLim then
            mainMenuScrollY = currentFieldY - yMaxLim
        end
        for i=1, #PageFiles do
            local attr = currentPage == i and INVERS or 0
            local y = (i-1)*lineSpacing + yMinLim - mainMenuScrollY
            if y >= 0 and y <= LCD_H then
                lcd.font(FONT_S)
                if currentPage == i then
                    lcd.color(ITEM_TEXT_SELECTED)
                else
                    lcd.color(ITEM_TEXT_NORMAL)
                end
                lcd.drawText(6, y, PageFiles[i].title)
            end
        end
    elseif uiState == uiStatus.pages then
        drawScreen()
        if pageState >= pageStatus.saving then
            local saveMsg = ""
            if pageState == pageStatus.saving then
                saveMsg = "Saving..."
                if saveRetries > 0 then
                    saveMsg = "sRetry #"..string.format("%u",saveRetries)
                end
            elseif pageState == pageStatus.eepromWrite then
                saveMsg = "eepromWrite"
                if saveRetries > 0 then
                    saveMsg = "eRetry #"..string.format("%u",saveRetries)
                end
            elseif pageState == pageStatus.rebooting then
                saveMsg = "Rebooting"
                -- if saveRetries > 0 then
                    -- saveMsg = "rRetry #"..string.format("%u",saveRetries)
                -- end
            end
            lcd.color(MENU_TITLE_BGCOLOR)
            lcd.drawFilledRectangle(radio.SaveBox.x,radio.SaveBox.y,radio.SaveBox.w,radio.SaveBox.h)
            lcd.color(MENU_TITLE_COLOR)
            lcd.drawRectangle(radio.SaveBox.x,radio.SaveBox.y,radio.SaveBox.w,radio.SaveBox.h)
            lcd.color(MENU_TITLE_COLOR)
            lcd.font(FONT_L)
            lcd.drawText(radio.SaveBox.x+radio.SaveBox.x_offset,radio.SaveBox.y+radio.SaveBox.h_offset,saveMsg)
        end
    elseif uiState == uiStatus.confirm then
        drawScreen()
    end

  -- drawScreenTitle(screenTitle) from ui.c
  if screenTitle then
    lcd.color(MENU_TITLE_BGCOLOR)
    lcd.drawFilledRectangle(0, 0, LCD_W, 30)
    lcd.color(MENU_TITLE_COLOR)
    lcd.font(FONT_S)
    lcd.drawText(5,5,screenTitle)
  end
  
  if rssiValue == 0 then
    lcd.color(ITEM_TEXT_EDITING)
    lcd.font(FONT_S)
    -- lcd.drawText(radio.NoTelem[1],radio.NoTelem[2],radio.NoTelem[3])
    lcd.drawText(LCD_W - 350, 5, "No Telemetry Connection!")
  end

end

local icon = lcd.loadMask("RF.png")

local function init()
  system.registerSystemTool({name=name, icon=icon, create=create, wakeup=wakeup, paint=paint, event=event})
end

return {init=init}