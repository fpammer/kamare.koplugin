-- A viewer-scoped network lease. Never alter saved Wi-Fi preferences.
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local logger = require("logger")
local Network = {}
Network.__index = Network

function Network.new()
    local self = setmetatable({ active = true }, Network)
    if Device:isPocketBook() then
        local ok, inkview = pcall(require, "ffi/inkview")
        if ok then
            self.inkview = inkview
        end
    end
    self.tick = function()
        if not self.active or self.suspended then
            return
        end
        if self.inkview and NetworkMgr:isWifiOn() then
            pcall(function()
                self.inkview.NetMgrPing()
            end)
        end
        UIManager:scheduleIn(30, self.tick)
    end
    if self.inkview then
        self.tick()
    end
    return self
end

-- Called by requests, not the keepalive timer: an idle viewer must not
-- reconnect behind the user's back. Rate-limit reconnects across all pages.
function Network:ready()
    if not self.active or self.suspended then
        return false
    end
    -- Preserve existing connection handling on platforms not tested here.
    if not self.inkview then
        return true
    end
    if NetworkMgr:isConnected() then
        return true
    end
    local now = time.to_s(time.now())
    if not self.last_reconnect or now - self.last_reconnect >= 30 then
        self.last_reconnect = now
        logger.info("Kamare: restoring connection for pending page")
        -- PocketBook NetConnect is synchronous; bound its frequency and do
        -- not extend this platform-specific behavior to Kobo/Kindle.
        local ok = pcall(function()
            NetworkMgr:turnOnWifi()
        end)
        if not ok then
            logger.warn("Kamare: reconnect failed")
        end
    end
    return NetworkMgr:isConnected()
end

function Network:onFailure(err)
    if not self.active or self.suspended or not self.inkview then
        return
    end
    -- PocketBook's libc may retain resolver configuration across reconnects.
    if not tostring(err):lower():find("name resolution", 1, true) then
        return
    end
    local now = time.to_s(time.now())
    if self.last_dns_reset and now - self.last_dns_reset < 30 then
        return
    end
    self.last_dns_reset = now
    local ffi = require("ffi")
    local ok, result = pcall(function()
        return ffi.C.res_init()
    end)
    if not ok then
        ok, result = pcall(function()
            return ffi.C.__res_init()
        end)
    end
    if ok and result == 0 then
        logger.info("Kamare: refreshed resolver after DNS failure")
    else
        logger.warn("Kamare: resolver refresh unavailable or failed")
    end
end

function Network:suspend()
    self.suspended = true
    UIManager:unschedule(self.tick)
end

function Network:resume()
    if not self.active then
        return
    end
    self.suspended = false
    self.last_reconnect = nil
    UIManager:unschedule(self.tick)
    if self.inkview then
        self.tick()
    end
end

function Network:close()
    self.active = false
    UIManager:unschedule(self.tick)
end

return Network
