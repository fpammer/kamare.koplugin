local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local KavitaBrowser = require("kavitabrowser")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Kamare = WidgetContainer:extend{
    name = "kamare",
    kamare_settings_file = DataStorage:getSettingsDir() .. "/kamare.lua",
    servers = nil,
}

function Kamare:init()
    self.kamare_settings = LuaSettings:open(self.kamare_settings_file)
    if next(self.kamare_settings.data) == nil then
        self.updated = true -- first run, force flush
    end
    self.servers = self.kamare_settings:readSetting("servers", {})
    -- Footer mode will be loaded by KamareImageViewer instances as needed
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
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
        servers = self.servers,
        title = _("Kavita Manga Reader"),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        _manager = self,
        close_callback = function()
            UIManager:close(self.browser)
        end,
    }

    UIManager:show(self.browser)
end

function Kamare:onFlushSettings()
    if self.updated then
        self.kamare_settings:flush()
        self.updated = nil
    end
end

return Kamare
