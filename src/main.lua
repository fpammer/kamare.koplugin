local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local KavitaBrowser = require("kavitabrowser")
local logger = require("logger")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local Kamare = WidgetContainer:extend{
    name = "kamare",
    kamare_settings_file = DataStorage:getSettingsDir() .. "/kamare.lua",
    servers = nil,
    -- CoverBrowser integration
    has_coverbrowser = false,
    BookInfoManager = nil,
    CoverMenu = nil,
    ListMenu = nil,
    MosaicMenu = nil,
}

function Kamare:init()
    self.kamare_settings = LuaSettings:open(self.kamare_settings_file)

    if next(self.kamare_settings.data) == nil then
        self.updated = true -- first run, force flush
        logger.info("Kamare: first run, initializing settings")
    end
    self.servers = self.kamare_settings:readSetting("servers", {})

    -- Try to load CoverBrowser modules
    self:loadCoverBrowserModules()

    -- Install BookInfoManager hook for Kavita metadata caching
    if self.has_coverbrowser then
        local BookInfoManagerHook = require("bookinfomanagerhook")
        BookInfoManagerHook:install(self)
    end

    -- Footer mode will be loaded by KamareImageViewer instances as needed
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Kamare:loadCoverBrowserModules()
    -- Try loading BookInfoManager
    local ok, module = pcall(require, "bookinfomanager")
    if ok then
        self.BookInfoManager = module
    else
        logger.warn("Kamare: Failed to load bookinfomanager:", module)
    end

    -- Try loading CoverMenu
    ok, module = pcall(require, "covermenu")
    if ok then
        self.CoverMenu = module
    else
        logger.warn("Kamare: Failed to load covermenu:", module)
    end

    -- Try loading ListMenu
    ok, module = pcall(require, "listmenu")
    if ok then
        self.ListMenu = module
    else
        logger.warn("Kamare: Failed to load listmenu:", module)
    end

    -- Try loading MosaicMenu
    ok, module = pcall(require, "mosaicmenu")
    if ok then
        self.MosaicMenu = module
    else
        logger.warn("Kamare: Failed to load mosaicmenu:", module)
    end

    -- Check if all modules loaded successfully
    if self.BookInfoManager and self.CoverMenu and self.ListMenu and self.MosaicMenu then
        self.has_coverbrowser = true
    else
        logger.warn("Kamare: CoverBrowser integration disabled - missing modules:",
                    "BookInfoManager=", self.BookInfoManager ~= nil,
                    "CoverMenu=", self.CoverMenu ~= nil,
                    "ListMenu=", self.ListMenu ~= nil,
                    "MosaicMenu=", self.MosaicMenu ~= nil)
    end
end

function Kamare:onDispatcherRegisterActions()
    Dispatcher:registerAction("kamare_show_catalog",
        {category="none", event="ShowKavitaBrowser", title=_("Kavita Manga Reader"), filemanager=true,}
    )
end

function Kamare:addToMainMenu(menu_items)
    menu_items.kamare = {
        text = _("Kavita Manga Reader"),
        sorting_hint = "search",
        callback = function()
            self:onShowKavitaBrowser()
        end,
    }
end

function Kamare:onShowKavitaBrowser()
    self.browser = KavitaBrowser:new{
        ui = self.ui,
        servers = self.servers,
        title = _("Kavita Manga Reader"),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        kamare_settings = self.kamare_settings,
        -- Pass CoverBrowser modules if available
        has_coverbrowser = self.has_coverbrowser,
        BookInfoManager = self.BookInfoManager,
        CoverMenu = self.CoverMenu,
        ListMenu = self.ListMenu,
        MosaicMenu = self.MosaicMenu,
        close_callback = function()
            UIManager:close(self.browser)
        end,
    }

    UIManager:show(self.browser)
end

function Kamare:getSettings()
    return self.kamare_settings
end

function Kamare:saveSettings()
    self.kamare_settings:flush()
    self.updated = nil
end

function Kamare:onFlushSettings()
    -- Always flush to ensure settings persistence
    self:saveSettings()
end

function Kamare:onResume()
    if self.browser then
        NetworkMgr:runWhenConnected(function()
            -- WiFi is connected now
            logger.dbg("Kamare: WiFi connected on resume, ready for streaming")
        end)
    end
end

return Kamare
