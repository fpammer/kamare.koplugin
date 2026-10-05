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
        if ok then self.inkview = inkview end
    end
    self.tick = function()
        if not self.active or self.suspended then return end
        if self.inkview and NetworkMgr:isWifiOn() then
            pcall(function() self.inkview.NetMgrPing() end)
        end
        UIManager:scheduleIn(30, self.tick)
    end
    self.tick()
    return self
end

-- Called by requests, not the keepalive timer: an idle viewer must not
-- reconnect behind the user's back. Rate-limit reconnects across all pages.
function Network:ready()
    if not self.active or self.suspended then return false end
    if NetworkMgr:isConnected() then return true end
    local now = time.to_s(time.now())
    if not self.last_reconnect or now - self.last_reconnect >= 30 then
        self.last_reconnect = now
        logger.info("Kamare: restoring connection for pending page")
        local ok = pcall(function() NetworkMgr:turnOnWifi() end)
        if not ok then logger.warn("Kamare: reconnect failed") end
    end
    return NetworkMgr:isConnected()
end

function Network:onFailure(err)
    if not self.active or self.suspended or not self.inkview then return end
    -- PocketBook's libc may retain resolver configuration across reconnects.
    if not tostring(err):lower():find("name resolution", 1, true) then return end
    local now = time.to_s(time.now())
    if self.last_dns_reset and now - self.last_dns_reset < 30 then return end
    self.last_dns_reset = now
    local ffi = require("ffi")
    local ok = pcall(function() ffi.C.res_init() end)
    if not ok then pcall(function() ffi.C.__res_init() end) end
    logger.info("Kamare: refreshing resolver after DNS failure")
end

function Network:suspend()
    self.suspended = true
    UIManager:unschedule(self.tick)
end

function Network:resume()
    if not self.active then return end
    self.suspended = false
    self.last_reconnect = nil
    UIManager:unschedule(self.tick)
    self.tick()
end

function Network:close()
    self.active = false
    UIManager:unschedule(self.tick)
end

return Network
