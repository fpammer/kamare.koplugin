local BD = require("ui/bidi")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Blitbuffer = require("ffi/blitbuffer")
local datetime = require("datetime")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local logger = require("logger")
local LuaSettings = require("luasettings")
local DocCache = require("document/doccache")
local DataStorage = require("datastorage")
local ConfigDialog = require("ui/widget/configdialog")
local CanvasContext = require("document/canvascontext")
local KamareOptions = require("kamareoptions")
local Configurable = require("frontend/configurable")
local InputContainer = require("ui/widget/container/inputcontainer")
local TitleBar = require("ui/widget/titlebar")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Size = require("ui/size")
local VirtualImageDocument = require("virtualimagedocument")
local KavitaClient = require("kavitaclient")
local _ = require("gettext")
local T = require("ffi/util").template

-- A simple widget to display a Blitbuffer
local BlitBufferWidget = ImageWidget:extend{
    blitbuffer = nil,
    -- We don't want this widget to free the blitbuffer, as it's owned by DocCache
    image_disposable = false,
}

function BlitBufferWidget:init()
    -- Set image to the provided blitbuffer
    -- NOTE: The parent _init has already been called by :new(), and ImageWidget
    --       does not define an init(), so don't call it here.
    self.image = self.blitbuffer
end

function BlitBufferWidget:free()
    -- Do not free self.image (the blitbuffer) as it's owned by DocCache
    self.image = nil
    ImageWidget.free(self)
end

local KamareImageViewer = InputContainer:extend{
    MODE = {
        page_progress = 1,
        pages_left_book = 2,
        time = 3,
        battery = 4,
        percentage = 5,
        book_time_to_read = 6,
        off = 7,
    },

    symbol_prefix = {
        letters = {
            time = nil,
            pages_left_book = "->",
            battery = "B:",
            percentage = "R:",
            book_time_to_read = "TB:",
        },
        icons = {
            time = "⌚",
            pages_left_book = "⇒",
            battery = "",
            percentage = "⤠",
            book_time_to_read = "⏳",
        },
        compact_items = {
            time = nil,
            pages_left_book = "›",
            battery = "",
            percentage = nil,
            book_time_to_read = nil
        }
    },

    -- Original image data (list of raw data or functions)
    images_list_data = nil,
    images_list_nb = nil,

    fullscreen = false,
    width = nil,
    height = nil,
    scale_factor = 0, -- 0 means fit to screen
    rotated = false,
    title = "",
    _center_x_ratio = 0.5,
    _center_y_ratio = 0.5,
    _image_wg = nil, -- Now a BlitBufferWidget
    _images_list_cur = 1,

    on_close_callback = nil,
    start_page = 1,

    configurable = Configurable:new(),
    options = KamareOptions,
    prefetch_pages = 1,

    image_padding = Size.margin.small,

    pan_threshold = Screen:scaleBySize(5),
    _panning = false,

    -- New: VirtualImageDocument instance
    virtual_document = nil,

    footer_settings = {
        enabled = true,
        page_progress = true,
        pages_left_book = true,
        time = true,
        battery = Device:hasBattery(),
        percentage = true,
        book_time_to_read = false,
        mode = 1,
        item_prefix = "icons",
        text_font_size = 14,
        text_font_bold = false,
        height = Screen:scaleBySize(15),
        disable_progress_bar = false,
        progress_bar_position = "alongside",
        progress_style_thin = false,
        progress_style_thin_height = 3,
        progress_style_thick_height = 7,
        progress_margin_width = 10,
        items_separator = "bar",
        align = "center",
        lock_tap = false,
    }
}

function KamareImageViewer:init()
    self:loadSettings()

    -- Set up gesture events once in init (like ImageViewer)
    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        local diagonal = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = range } },
            Hold = { GestureRange:new{ ges = "hold", range = range } },
            HoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
            Pan = { GestureRange:new{ ges = "pan", range = range } },
            PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
            Swipe = { GestureRange:new{ ges = "swipe", range = range } },
            TwoFingerTap = { GestureRange:new{ ges = "two_finger_tap",
                    scale = {diagonal - Screen:scaleBySize(200), diagonal}, rate = 1.0,
                }
            },
            MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = range } },
            Spread = { GestureRange:new{ ges = "spread", range = range } },
            Pinch = { GestureRange:new{ ges = "pinch", range = range } },
        }
    end

    if self.fullscreen then
        self.covers_fullscreen = true
    end

    self.mode_index = {
        [1] = "page_progress",
        [2] = "pages_left_book",
        [3] = "time",
        [4] = "battery",
        [5] = "percentage",
        [6] = "book_time_to_read",
        [7] = "off",
    }

    self.image_viewing_times = {}
    self.current_image_start_time = os.time()

    self.title_bar_visible = false

    -- Ensure CanvasContext is initialized so color rendering can be enabled when supported
    if not CanvasContext.device then
        CanvasContext:init(Device)
    end

    -- Create VirtualImageDocument
    local has_valid_images_data = true
    if not self.images_list_data then
        logger.err("KamareImageViewer: No images_list_data provided. Displaying empty screen.")
        has_valid_images_data = false
        -- Provide a dummy images_list_data to create a VirtualImageDocument that will show placeholders
        self.images_list_data = { function() return nil end } -- A function that returns nil will trigger placeholder in VirtualImageDocument
        self.images_list_nb = 1
    end

    -- Build a stable cache identity for this virtual document
    local cache_id = (self.metadata and (self.title .. '/' .. self.metadata.seriesId .. '/' .. self.metadata.chapterId)) or self.title or "session"

    logger.dbg("KamareImageViewer: Initializing VirtualImageDocument with cache_id =", cache_id)

    self.virtual_document = VirtualImageDocument:new{
        images_list = self.images_list_data,
        pages_override = self.images_list_nb,
        title = self.title,
        cache_id = cache_id,
        cache_mod_time = 0, -- keep stable across sessions
    }

    if self.preloaded_dimensions then
        self.virtual_document:preloadDimensions(self.preloaded_dimensions)
    end

    if not self.virtual_document.is_open then
        logger.err("KamareImageViewer: Failed to initialize VirtualImageDocument. Displaying empty screen.")
        -- Even if VirtualImageDocument fails, we want to keep the viewer open to show something.
        -- The VirtualImageDocument's renderPage will return placeholders.
        self.is_open = true
    end

    self._images_list_nb = self.virtual_document:getPageCount()
    self._images_list_cur = (self.metadata and self.metadata.startPage) or 1
    if self._images_list_cur < 1 then
        self._images_list_cur = 1
    end
    if self._images_list_cur > self._images_list_nb then
        self._images_list_cur = self._images_list_nb
    end

    logger.dbg("KamareImageViewer: initialized with start_page =", self._images_list_cur, "of", self._images_list_nb)

    -- Initial rotation check based on current start page's dimensions
    -- Only attempt if we actually have valid image data, otherwise it will use placeholder dims
    if has_valid_images_data then
        local first_page_dims = self.virtual_document:getNativePageDimensions(self._images_list_cur)
        if first_page_dims and G_reader_settings:isTrue("imageviewer_rotate_auto_for_best_fit") then
            self.rotated = (Screen:getWidth() > Screen:getHeight()) ~= (first_page_dims.w > first_page_dims.h)
        end
    end

    self.align = "center"
    self.region = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    if self.fullscreen then
        self.height = Screen:getHeight()
        self.width = Screen:getWidth()
    else
        self.height = Screen:getHeight() - Screen:scaleBySize(40)
        self.width = Screen:getWidth() - Screen:scaleBySize(40)
    end

    self:registerKeyEvents()

    self:setupTitleBar()
    self:initConfigGesListener()

    self.footerTextGeneratorMap = {
        empty = function() return "" end,

        page_progress = function()
            if not self.virtual_document or self._images_list_nb <= 1 then
                return ""
            end
            return ("%d / %d"):format(self._images_list_cur, self._images_list_nb)
        end,

        pages_left_book = function()
            if not self.virtual_document or self._images_list_nb <= 1 then
                return ""
            end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].pages_left_book
            local remaining = self._images_list_nb - self._images_list_cur
            return prefix and (prefix .. " " .. remaining) or tostring(remaining)
        end,

        time = function()
            if not self.footer_settings.time then return "" end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].time
            local clock = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
            if not prefix then
                return clock
            else
                return prefix .. " " .. clock
            end
        end,

        battery = function()
            if not Device:hasBattery() or not self.footer_settings.battery then
                return ""
            end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].battery
            local powerd = Device:getPowerDevice()
            local batt_lvl = powerd:getCapacity()
            local is_charging = powerd:isCharging()

            if symbol_type == "icons" or symbol_type == "compact_items" then
                if symbol_type == "compact_items" then
                    return BD.wrap(prefix)
                else
                    return BD.wrap(prefix) .. batt_lvl .. "%"
                end
            else
                return BD.wrap(prefix) .. " " .. (is_charging and "+" or "") .. batt_lvl .. "%"
            end
        end,

        percentage = function()
            if not self.virtual_document or self._images_list_nb <= 1 then
                return ""
            end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].percentage
            local progress = (self._images_list_cur - 1) / (self._images_list_nb - 1) * 100
            local string_percentage = "%.1f%%"
            if prefix then
                string_percentage = prefix .. " " .. string_percentage
            end
            return string_percentage:format(progress)
        end,

        book_time_to_read = function()
            if not self.virtual_document or self._images_list_nb <= 1 then
                return ""
            end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].book_time_to_read
            local remaining = self._images_list_nb - self._images_list_cur
            local time_estimate = self:getTimeEstimate(remaining)
            return (prefix and prefix .. " " or "") .. time_estimate
        end,
    }

    self:updateFooterTextGenerator()

    -- Container for the above elements, that we will reset and refill
    self.frame_elements = VerticalGroup:new{ align = "left" }

    self.main_frame = FrameContainer:new{
        radius = not self.fullscreen and 8 or nil,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.frame_elements,
    }
    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.main_frame,
    }

    -- Setup footer if we have multiple images
    if self.virtual_document and self._images_list_nb > 1 then
        self:setupFooter()
        -- Initialize footer visibility
        self.footer_visible = (self.footer_settings.mode ~= self.MODE.off)
    end

    self:update()
    UIManager:nextTick(function()
        self:prefetchUpcomingTiles()
        self:_postViewProgress()
    end)
end

function KamareImageViewer:registerKeyEvents()
    if not Device:hasKeys() then
        return
    end

    self.key_events = {
        Close = { { Device.input.group.Back } },
        ShowPrevImage = { { Device.input.group.PgBack } },
        ShowNextImage = { { Device.input.group.PgFwd } },
    }
end


function KamareImageViewer:getKamareSettings()
    if self.ui and self.ui.kamare and self.ui.kamare.kamare_settings then
        return self.ui.kamare.kamare_settings
    end

    local kamare_settings_file = DataStorage:getSettingsDir() .. "/kamare.lua"
    local kamare_settings = LuaSettings:open(kamare_settings_file)

    if next(kamare_settings.data) ~= nil then
        return kamare_settings
    else
        kamare_settings:close()
        return nil
    end
end

function KamareImageViewer:loadSettings()
    local kamare_settings = self:getKamareSettings()
    if kamare_settings then
        self.configurable:loadSettings(kamare_settings, self.options.prefix.."_")

        if self.configurable.footer_mode then
            self.footer_settings.mode = tonumber(self.configurable.footer_mode) or self.footer_settings.mode
        end
        -- Prefetch pages count
        if self.configurable.prefetch_pages ~= nil then
            self.prefetch_pages = tonumber(self.configurable.prefetch_pages) or 1
        else
            self.prefetch_pages = 1
        end
    else
        self.prefetch_pages = 1
    end

    -- Keep config fields in sync so ConfigDialog reflects current state
    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages
end

function KamareImageViewer:syncAndSaveSettings()
    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages
    self:saveSettings()
end

function KamareImageViewer:saveSettings()
    local kamare_settings = self:getKamareSettings()
    if kamare_settings then
        self.configurable:saveSettings(kamare_settings, self.options.prefix.."_")
        kamare_settings:flush()
    end
end

function KamareImageViewer:getCurrentFooterMode()
    return self.footer_settings.mode
end

function KamareImageViewer:isValidMode(mode)
    mode = tonumber(mode)
    if not mode then
        return false
    end
    if mode == self.MODE.off then
        return true
    end

    local mode_name = self.mode_index[mode]
    if not mode_name then
        return false
    end

    local is_enabled = self.footer_settings[mode_name]
    return is_enabled
end

function KamareImageViewer:cycleToNextValidMode()
    local max_modes = #self.mode_index
    local attempts = 0

    self.footer_settings.mode = (self.footer_settings.mode % max_modes) + 1

    while attempts < max_modes do
        if self:isValidMode(self.footer_settings.mode) then
            break
        else
            self.footer_settings.mode = (self.footer_settings.mode % max_modes) + 1
        end
        attempts = attempts + 1
    end

    if attempts >= max_modes then
        self.footer_settings.mode = self.MODE.off
    end

    self:syncAndSaveSettings()
    self:applyFooterMode()

    return self.footer_settings.mode
end

function KamareImageViewer:setFooterMode(new_mode)
    if new_mode == nil then
        logger.warn("setFooterMode called with nil mode, ignoring")
        return false
    end

    if not self:isValidMode(new_mode) then
        logger.warn("Attempt to set invalid mode:", new_mode)
        return false
    end

    self.footer_settings.mode = tonumber(new_mode) or self.footer_settings.mode

    self:syncAndSaveSettings()
    self:applyFooterMode()
    return true
end

function KamareImageViewer:initConfigGesListener()
    if not Device:isTouchDevice() then return end

    local DTAP_ZONE_MENU = G_defaults:readSetting("DTAP_ZONE_MENU")
    local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    local DTAP_ZONE_CONFIG = G_defaults:readSetting("DTAP_ZONE_CONFIG")
    local DTAP_ZONE_CONFIG_EXT = G_defaults:readSetting("DTAP_ZONE_CONFIG_EXT")
    local DTAP_ZONE_MINIBAR = G_defaults:readSetting("DTAP_ZONE_MINIBAR")
    local DTAP_ZONE_FORWARD = G_defaults:readSetting("DTAP_ZONE_FORWARD")
    local DTAP_ZONE_BACKWARD = G_defaults:readSetting("DTAP_ZONE_BACKWARD")

    self:registerTouchZones({
        {
            id = "kamare_menu_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
            },
            handler = function() return self:onTapMenu() end,
        },
        {
            id = "kamare_menu_ext_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MENU_EXT.x, ratio_y = DTAP_ZONE_MENU_EXT.y,
                ratio_w = DTAP_ZONE_MENU_EXT.w, ratio_h = DTAP_ZONE_MENU_EXT.h,
            },
            overrides = {
                "kamare_menu_tap",
            },
            handler = function() return self:onTapMenu() end,
        },
        {
            id = "kamare_config_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_CONFIG.x, ratio_y = DTAP_ZONE_CONFIG.y,
                ratio_w = DTAP_ZONE_CONFIG.w, ratio_h = DTAP_ZONE_CONFIG.h,
            },
            handler = function() return self:onTapConfig() end,
        },
        {
            id = "kamare_config_ext_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_CONFIG_EXT.x, ratio_y = DTAP_ZONE_CONFIG_EXT.y,
                ratio_w = DTAP_ZONE_CONFIG_EXT.w, ratio_h = DTAP_ZONE_CONFIG_EXT.h,
            },
            overrides = {
                "kamare_config_tap",
            },
            handler = function() return self:onTapConfig() end,
        },
        {
            id = "kamare_forward_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_FORWARD.x, ratio_y = DTAP_ZONE_FORWARD.y,
                ratio_w = DTAP_ZONE_FORWARD.w, ratio_h = DTAP_ZONE_FORWARD.h,
            },
            handler = function() return self:onTapForward() end,
        },
        {
            id = "kamare_backward_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_BACKWARD.x, ratio_y = DTAP_ZONE_BACKWARD.y,
                ratio_w = DTAP_ZONE_BACKWARD.w, ratio_h = DTAP_ZONE_BACKWARD.h,
            },
            handler = function() return self:onTapBackward() end,
        },
        {
            id = "kamare_minibar_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MINIBAR.x, ratio_y = DTAP_ZONE_MINIBAR.y,
                ratio_w = DTAP_ZONE_MINIBAR.w, ratio_h = DTAP_ZONE_MINIBAR.h,
            },
            handler = function() return self:onTapMinibar() end,
        },
    })
end

function KamareImageViewer:onShowConfigMenu()
    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages

    self.config_dialog = ConfigDialog:new{
        document = nil,
        ui = self.ui or self,
        configurable = self.configurable,
        config_options = self.options,
        is_always_active = true,
        covers_footer = true,
        close_callback = function()
            self:onConfigCloseCallback()
        end,
    }

    self.config_dialog:onShowConfigPanel(1)
    UIManager:show(self.config_dialog)
    return true
end

function KamareImageViewer:onConfigCloseCallback()
    self.config_dialog = nil

    local footer_mode = self.configurable.footer_mode
    if footer_mode and footer_mode ~= self.footer_settings.mode then
        self:setFooterMode(footer_mode)
    end

    self:syncAndSaveSettings()
end

function KamareImageViewer:onCloseConfigMenu()
    if self.config_dialog then
        self.config_dialog:closeDialog()
    end
end

function KamareImageViewer:onSetFooterMode(...)
    local args = {...}
    local mode = tonumber(args[1])

    if self:setFooterMode(mode) then
        return true
    end

    return false
end

function KamareImageViewer:onSetPrefetchPages(...)
    local args = {...}
    local value = args[1]
    local n = tonumber(value)
    if not n then
        logger.warn("onSetPrefetchPages: invalid value:", value)
        return false
    end
    if n < 0 then n = 0 end
    if n > 10 then n = 10 end -- safety clamp

    if n == self.prefetch_pages then
        return true
    end

    self.prefetch_pages = n
    self.configurable.prefetch_pages = n

    self:syncAndSaveSettings()

    UIManager:nextTick(function()
        self:prefetchUpcomingTiles()
    end)
    return true
end

function KamareImageViewer:onDefineZoom(...)
    local args = {...}
    local v = tonumber(args[1])
    if v ~= nil then
        self.configurable.zoom_mode_type = v
        self:saveSettings()
        return true
    end
    return false
end

function KamareImageViewer:onTapMenu()
    self:toggleTitleBar()
    return true
end

function KamareImageViewer:onTapConfig()
    return self:onShowConfigMenu()
end

function KamareImageViewer:onTapMinibar()
    if not self.footer_settings.enabled or not self.virtual_document or self._images_list_nb <= 1 then
        return false
    end

    if self.footer_settings.lock_tap then
        return self:onShowConfigMenu()
    end

    self:cycleToNextValidMode()
    return true
end

function KamareImageViewer:onTapForward()
    if BD.mirroredUILayout() then
        self:onShowPrevImage()
    else
        self:onShowNextImage()
    end
    return true
end

function KamareImageViewer:onTapBackward()
    if BD.mirroredUILayout() then
        self:onShowNextImage()
    else
        self:onShowPrevImage()
    end
    return true
end

function KamareImageViewer:setupTitleBar()
    local title = self.title or _("Images")
    local subtitle

    if self.metadata then
        title = self.metadata.seriesName or self.metadata.localizedName or self.metadata.originalName or title
        if self.metadata.author then
            subtitle = T(_("by %1"), self.metadata.author)
        end
    end

    self.title_bar = TitleBar:new{
        width = Screen:getWidth(),
        fullscreen = true,
        align = "center",
        title = title,
        subtitle = subtitle,
        title_shrink_font_to_fit = true,
        title_top_padding = Screen:scaleBySize(6),
        button_padding = Screen:scaleBySize(5),
        right_icon_size_ratio = 1,
        with_bottom_line = true,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }
end

function KamareImageViewer:setupFooter()
    self.footer_text_face = Font:getFace("ffont", self.footer_settings.text_font_size)
    self.footer_text = TextWidget:new{
        text = "",
        face = self.footer_text_face,
        bold = self.footer_settings.text_font_bold,
    }

    self.progress_bar = ProgressWidget:new{
        width = Screen:getWidth() - 2 * Screen:scaleBySize(self.footer_settings.progress_margin_width),
        height = self.footer_settings.progress_style_thick_height,
        percentage = 0,
        tick_width = 0,
        ticks = nil,
        last = nil,
        initial_pos_marker = false,
    }

    self.progress_bar:updateStyle(true, self.footer_settings.progress_style_thick_height)

    self.footer_left_margin_span = HorizontalSpan:new{ width = Screen:scaleBySize(self.footer_settings.progress_margin_width) }

    self.footer_right_margin_span = HorizontalSpan:new{ width = Screen:scaleBySize(self.footer_settings.progress_margin_width) }

    self.footer_text_container = CenterContainer:new{
        dimen = Geom:new{ w = 0, h = self.footer_settings.height },
        self.footer_text,
    }

    self.footer_horizontal_group = HorizontalGroup:new{
        self.footer_left_margin_span,
        self.progress_bar,
        self.footer_text_container,
        self.footer_right_margin_span,
    }

    self.footer_vertical_frame = VerticalGroup:new{
        self.footer_horizontal_group
    }

    self.footer_content = FrameContainer:new{
        self.footer_vertical_frame,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        padding_bottom = 0,
    }

    self.footer_content.dimen = Geom:new{
        w = Screen:getWidth(),
        h = self.footer_settings.height,
    }
    self.footer = self.footer_content

    self:refreshFooter()
end

function KamareImageViewer:updateFooterTextGenerator()
    if not self.footer_settings.enabled then
        self.genFooterText = self.footerTextGeneratorMap.empty
        return
    end

    if not self:isValidMode(self.footer_settings.mode) then
        self.genFooterText = self.footerTextGeneratorMap.empty
        return
    end

    local mode_name = self.mode_index[self.footer_settings.mode]
    self.genFooterText = self.footerTextGeneratorMap[mode_name] or self.footerTextGeneratorMap.empty
end

function KamareImageViewer:updateFooterContent()
    if not self.footer_text then
        return
    end

    if not self.genFooterText then
        self.genFooterText = self.footerTextGeneratorMap.empty
        self:updateFooterTextGenerator()
    end

    local new_font_face = Font:getFace("ffont", self.footer_settings.text_font_size)
    if new_font_face ~= self.footer_text_face then
        self.footer_text_face = new_font_face
        local current_text = self.footer_text.text
        self.footer_text:free()
        self.footer_text = TextWidget:new{
            text = current_text,
            face = self.footer_text_face,
            bold = self.footer_settings.text_font_bold,
        }
        self.footer_text_container[1] = self.footer_text
    elseif self.footer_settings.text_font_bold ~= self.footer_text.bold then
        local current_text = self.footer_text.text
        self.footer_text:free()
        self.footer_text = TextWidget:new{
            text = current_text,
            face = self.footer_text_face,
            bold = self.footer_settings.text_font_bold,
        }
        self.footer_text_container[1] = self.footer_text
    end

    local text = self.genFooterText()
    self.footer_text:setText(text)

    local margins_width = 2 * Screen:scaleBySize(self.footer_settings.progress_margin_width)

    local min_progress_width = math.floor(Screen:getWidth() * 0.20)
    local text_available_width = Screen:getWidth() - margins_width - min_progress_width

    self.footer_text:setMaxWidth(text_available_width)
    local text_size = self.footer_text:getSize()

    local text_spacer = Screen:scaleBySize(10)
    local text_container_width = text_size.w + text_spacer

    if text == "" or text_size.w <= 0 then
        self.footer_text_container.dimen.w = 0
        self.progress_bar.width = Screen:getWidth() - 2 * Screen:scaleBySize(self.footer_settings.progress_margin_width)
    else
        self.footer_text_container.dimen.w = text_container_width
        self.progress_bar.width = math.max(min_progress_width,
            Screen:getWidth() - margins_width - text_container_width)
    end

    self.footer_left_margin_span.width = Screen:scaleBySize(self.footer_settings.progress_margin_width)
    self.footer_right_margin_span.width = Screen:scaleBySize(self.footer_settings.progress_margin_width)

    self.footer_horizontal_group:resetLayout()
end

function KamareImageViewer:refreshFooter()
    self:updateFooterContent()
    self:updateProgressBar()
    if self.footer then
        UIManager:setDirty(self, "ui", self.footer.dimen)
    end
end

function KamareImageViewer:updateProgressBar()
    if not self.progress_bar or self.footer_settings.disable_progress_bar then
        return
    end

    if not self.virtual_document or self._images_list_nb <= 1 then
        self.progress_bar:setPercentage(0)
        return
    end

    local progress = (self._images_list_cur - 1) / (self._images_list_nb - 1)
    self.progress_bar:setPercentage(progress)
end

function KamareImageViewer:getTimeEstimate(remaining_images)
    if #self.image_viewing_times == 0 then
        return _("N/A")
    end

    local total_time = 0
    for _, time in ipairs(self.image_viewing_times) do
        total_time = total_time + time
    end
    local avg_time = total_time / #self.image_viewing_times

    local remaining_seconds = remaining_images * avg_time

    if remaining_seconds < 60 then
        return T(_("%1s"), math.ceil(remaining_seconds))
    elseif remaining_seconds < 3600 then
        return T(_("%1m"), math.ceil(remaining_seconds / 60))
    else
        local hours = math.floor(remaining_seconds / 3600)
        local minutes = math.ceil((remaining_seconds % 3600) / 60)
        return T(_("%1h %2m"), hours, minutes)
    end
end

function KamareImageViewer:recordViewingTimeIfValid()
    if self.current_image_start_time and self._images_list_cur then
        local viewing_time = os.time() - self.current_image_start_time
        if viewing_time > 0 and viewing_time < 300 then
            table.insert(self.image_viewing_times, viewing_time)
            if #self.image_viewing_times > 10 then
                table.remove(self.image_viewing_times, 1)
            end
        end
    end
end

function KamareImageViewer:switchToImageNum(image_num)
    self:recordViewingTimeIfValid()

    if image_num == self._images_list_cur then
        return
    end

    self._images_list_cur = image_num
    self._center_x_ratio = 0.5
    self._center_y_ratio = 0.5
    self.scale_factor = 0 -- Reset to fit-to-screen so the complete image is visible
    self.current_image_start_time = os.time()

    self:updateImageOnly()
    self:refreshFooter()
    self:_postViewProgress()
    UIManager:nextTick(function()
        self:prefetchUpcomingTiles()
    end)
end

function KamareImageViewer:onShowNextImage()
    if self._images_list_cur < self._images_list_nb then
        self:switchToImageNum(self._images_list_cur + 1)
    end
end

function KamareImageViewer:onShowPrevImage()
    if self._images_list_cur > 1 then
        self:switchToImageNum(self._images_list_cur - 1)
    end
end

function KamareImageViewer:applyFooterMode()
    local prev_visible = self.footer_visible
    self.footer_visible = (self.footer_settings.mode ~= self.MODE.off)

    self:updateFooterTextGenerator()
    if self.footer_visible ~= prev_visible then
        self:update()
    else
        self:refreshFooter()
    end
end

function KamareImageViewer:toggleTitleBar()
    self.title_bar_visible = not self.title_bar_visible

    if not self.title_bar then
        self:setupTitleBar()
    end

    self:update()
end

function KamareImageViewer:update()
    self:_clean_image_wg()

    local orig_dimen = self.main_frame.dimen
    if self.fullscreen then
        self.height = Screen:getHeight()
        self.width = Screen:getWidth()
    else
        self.height = Screen:getHeight() - Screen:scaleBySize(40)
        self.width = Screen:getWidth() - Screen:scaleBySize(40)
    end

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    if self.title_bar_visible and self.title_bar then
        table.insert(self.frame_elements, self.title_bar)
    end
    local image_container_idx = #self.frame_elements + 1
    if self.virtual_document and self._images_list_nb > 1 and
       self.footer and self.footer_visible then
        self:updateFooterContent()
        self:updateProgressBar()
        table.insert(self.frame_elements, self.footer)
    end
    self.img_container_h = self.height - self.frame_elements:getSize().h
    self:_new_image_wg()
    if self.image_container then
        table.insert(self.frame_elements, image_container_idx, self.image_container)
    end
    self.frame_elements:resetLayout()

    self.main_frame.radius = not self.fullscreen and 8 or nil

    UIManager:setDirty(self, function()
        local update_region = self.main_frame.dimen:combine(orig_dimen)
        return "partial", update_region
    end)
end

-- Prefetch the next N pages' full tiles (fit-to-screen) into DocCache.
function KamareImageViewer:updateImageOnly()
    if not (self.image_container and self.frame_elements) then
        return self:update()
    end

    local old_container = self.image_container
    local old_wg = self._image_wg

    self:_new_image_wg()
    local new_container = self.image_container

    local replaced = false
    for i = 1, #self.frame_elements do
        if self.frame_elements[i] == old_container then
            self.frame_elements[i] = new_container
            replaced = true
            break
        end
    end
    if not replaced then
        table.insert(self.frame_elements, new_container)
    end

    if old_wg then pcall(function() old_wg:free() end) end
    if old_container then pcall(function() old_container:free() end) end

    self.frame_elements:resetLayout()

    UIManager:setDirty(self, "partial", new_container.dimen)
end

function KamareImageViewer:prefetchUpcomingTiles()
    if not self.virtual_document then return end
    local count = tonumber(self.prefetch_pages) or 0
    if count <= 0 then return end

    -- Base size ignoring chrome so prefetch renders at full-screen zoom
    local base_w = self.width - self.image_padding*2
    local base_h = self.height - self.image_padding*2

    local rotation_angle = self:_getRotationAngle()
    local gamma = 1.0

    for i = 1, count do
        local page = (self._images_list_cur or 0) + i
        if page > (self._images_list_nb or 0) then break end

        UIManager:nextTick(function()
            pcall(function()
                -- Ensure MuPDF dims are resolved before computing zoom policy
                self.virtual_document:ensureDims(page)
                local dims = self.virtual_document:getNativePageDimensions(page)
                if not dims or dims.w <= 0 or dims.h <= 0 then return end

                local w0, h0 = dims.w, dims.h
                if rotation_angle == 90 or rotation_angle == 270 then
                    w0, h0 = h0, w0
                end
                if w0 <= 0 or h0 <= 0 then return end

                local zoom_w = base_w / w0
                local zoom_h = base_h / h0
                local view_aspect = base_w / base_h
                local page_aspect = w0 / h0
                local is_wide = page_aspect > (view_aspect + 0.01)

                if is_wide then
                    -- Match on-screen policy: prefetch full page at fit-to-width
                    local zoom = zoom_w
                    self.virtual_document:prefetchPage(page, zoom, rotation_angle, gamma)
                else
                    -- Full-page prefetch (persistent tile) at fit-inside zoom
                    local zoom = math.min(zoom_w, zoom_h)
                    if not (zoom and zoom > 0) then
                        zoom = self._scale_factor_0 or 1.0
                    end
                    self.virtual_document:prefetchPage(page, zoom, rotation_angle, gamma)
                end
            end)
        end)
    end
end

-- Post reading progress for the currently viewed page (if configured).
function KamareImageViewer:_postViewProgress()
    if not (self.metadata and KavitaClient and KavitaClient.bearer) then return end
    if self.last_posted_page == self._images_list_cur then return end
    local page1 = self._images_list_cur -- Kavita expects 1-based count of pages read
    UIManager:nextTick(function()
        pcall(function()
            KavitaClient:postReaderProgressForPage(self.metadata, page1)
        end)
    end)
    self.last_posted_page = page1
end


function KamareImageViewer:_clean_image_wg()
    if self._image_wg then
        self._image_wg:free()
        self._image_wg = nil
    end
end

function KamareImageViewer:_getRotationAngle()
    if not self.rotated then return 0 end

    local rotate_clockwise
    if Screen:getWidth() <= Screen:getHeight() then
        rotate_clockwise = G_reader_settings:isTrue("imageviewer_rotation_portrait_invert") or false
    else
        rotate_clockwise = not G_reader_settings:isTrue("imageviewer_rotation_landscape_invert")
    end
    return rotate_clockwise and 270 or 90
end

-- Helper to clamp a value between bounds
local function clamp(v, lo, hi)
    return math.max(lo, math.min(v, hi))
end

function KamareImageViewer:_effectiveZoom()
    if self.scale_factor == 0 then
        return self._scale_factor_0 or (self._image_wg and self._image_wg.getScaleFactor and self._image_wg:getScaleFactor()) or 1.0
    else
        return self.scale_factor
    end
end

-- Compute device-space (after zoom/rotation) viewport of size vw x vh centered on current center ratios
function KamareImageViewer:_computeViewport(native_dims, zoom, rotation_angle, vw, vh)
    local page_size = self.virtual_document:transformRect(native_dims, zoom, rotation_angle)
    local ww = math.min(vw, page_size.w)
    local hh = math.min(vh, page_size.h)

    local cx = page_size.w * self._center_x_ratio
    local cy = page_size.h * self._center_y_ratio
    local x = math.floor(cx - ww / 2 + 0.5)
    local y = math.floor(cy - hh / 2 + 0.5)

    x = clamp(x, 0, math.max(0, page_size.w - ww))
    y = clamp(y, 0, math.max(0, page_size.h - hh))

    return page_size, Geom:new{ x = x, y = y, w = ww, h = hh }
end

function KamareImageViewer:_new_image_wg()
    local max_image_h = self.img_container_h
    local max_image_w = self.width
    if self.footer_visible or self.title_bar_visible then
        max_image_h = self.img_container_h - self.image_padding*2
        max_image_w = self.width - self.image_padding*2
    end

    -- Compute a base size ignoring chrome (titlebar/footer) so the render zoom stays stable across toggles.
    local base_image_w = self.width - self.image_padding*2
    local base_image_h = self.height - self.image_padding*2

    local rotation_angle = self:_getRotationAngle()
    local current_page_num = self._images_list_cur
    local current_gamma = 1.0 -- Assuming no gamma control in KamareImageViewer directly

    -- Get native dimensions of the current image
    self.virtual_document:ensureDims(current_page_num)
    local native_dims = self.virtual_document:getNativePageDimensions(current_page_num)
    if not native_dims or native_dims.w == 0 or native_dims.h == 0 then
        logger.warn("KamareImageViewer: Could not get native dimensions for page", current_page_num)
        -- Fallback to a placeholder
        self._image_wg = BlitBufferWidget:new{
            blitbuffer = Blitbuffer.new(max_image_w, max_image_h, Blitbuffer.TYPE_GRAY),
            width = max_image_w,
            height = max_image_h,
        }
        self._image_wg.blitbuffer:fill(Blitbuffer.COLOR_LIGHT_GRAY)
        self.image_container = CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.img_container_h },
            self._image_wg,
        }
        return
    end

    local current_zoom = self.scale_factor
    local zoom_w, zoom_h
    if current_zoom == 0 then -- Fit to screen (account for rotation)
        local w0, h0 = native_dims.w, native_dims.h
        if rotation_angle == 90 or rotation_angle == 270 then
            w0, h0 = h0, w0
        end
        zoom_w = base_image_w / w0
        zoom_h = base_image_h / h0
        current_zoom = math.min(zoom_w, zoom_h)
        self._scale_factor_0 = current_zoom -- Cache for zoom in/out
    end

    -- Render strategy:
    -- - Fit-to-screen (scale_factor == 0): render full page once (rect = nil) to avoid double fetch.
    -- - Zoomed/panned (scale_factor > 0): render only the viewport window.
    local tile
    local widget_w, widget_h, widget_scale
    if self.scale_factor == 0 then
        -- Dynamic wide check from MuPDF dims (after rotation)
        local w0, h0 = native_dims.w, native_dims.h
        if rotation_angle == 90 or rotation_angle == 270 then
            w0, h0 = h0, w0
        end
        local page_aspect = w0 / h0
        local view_aspect = base_image_w / base_image_h
        local is_wide = page_aspect > (view_aspect + 0.01)
        if is_wide then
            -- Fit-by-width for wide pages: render full page at zoom_w
            current_zoom = zoom_w or current_zoom
            self._scale_factor_0 = current_zoom

            tile = self.virtual_document:renderPage(
                current_page_num,
                nil,
                current_zoom,
                rotation_angle,
                current_gamma
            )

            -- After first render (or cache hit), native dims may have been corrected.
            -- Recompute fit-by-width zoom and re-render if it changed meaningfully.
            do
                local dims_now = self.virtual_document:getNativePageDimensions(current_page_num)
                if dims_now and dims_now.w > 0 and dims_now.h > 0 then
                    local w0, h0 = dims_now.w, dims_now.h
                    if rotation_angle == 90 or rotation_angle == 270 then
                        w0, h0 = h0, w0
                    end
                    local zoom_w2 = base_image_w / w0
                    if math.abs(zoom_w2 - current_zoom) > 0.02 then
                        tile = self.virtual_document:renderPage(
                            current_page_num,
                            nil,
                            zoom_w2,
                            rotation_angle,
                            current_gamma
                        )
                        self._scale_factor_0 = zoom_w2
                        current_zoom = zoom_w2
                    end
                end
            end

            -- Full-page tile; display 1:1
            widget_w = max_image_w
            widget_h = max_image_h
            widget_scale = 0
        else
            -- Regular: full page render at min zoom
            tile = self.virtual_document:renderPage(
                current_page_num,
                nil,
                current_zoom,
                rotation_angle,
                current_gamma
            )
            -- After first render, MuPDF dims are cached; recompute fit once and re-render if needed
            do
                local dims_now = self.virtual_document:getNativePageDimensions(current_page_num)
                if dims_now and dims_now.w > 0 and dims_now.h > 0 then
                    local w0, h0 = dims_now.w, dims_now.h
                    if rotation_angle == 90 or rotation_angle == 270 then
                        w0, h0 = h0, w0
                    end
                    local zoom_w2 = base_image_w / w0
                    local zoom_h2 = base_image_h / h0
                    local fit_zoom2 = math.min(zoom_w2, zoom_h2)
                    if math.abs(fit_zoom2 - current_zoom) > 0.02 then
                        tile = self.virtual_document:renderPage(
                            current_page_num,
                            nil,
                            fit_zoom2,
                            rotation_angle,
                            current_gamma
                        )
                        self._scale_factor_0 = fit_zoom2
                        current_zoom = fit_zoom2
                    end
                end
            end
            widget_w = max_image_w
            widget_h = max_image_h
            widget_scale = 0
        end
    else
        -- Compute viewport in device space for current zoom/rotation and container size
        local _, viewport = self:_computeViewport(native_dims, current_zoom, rotation_angle, max_image_w, max_image_h)
        -- Request only the visible window from the document
        local rect = Geom:new{
            x = viewport.x / current_zoom,
            y = viewport.y / current_zoom,
            w = viewport.w / current_zoom,
            h = viewport.h / current_zoom,
            scaled_rect = viewport,
        }

        tile = self.virtual_document:renderPage(
            current_page_num,
            rect,
            current_zoom,
            rotation_angle,
            current_gamma
        )
        -- Display cropped tile 1:1
        widget_w = rect.scaled_rect.w
        widget_h = rect.scaled_rect.h
        widget_scale = 1
    end

    if tile and tile.bb then
        -- If we rendered a full-page tile (widget_scale == 0), display it 1:1 to avoid a second fit in ImageWidget.
        local w, h, sf = widget_w, widget_h, widget_scale
        self._image_wg = BlitBufferWidget:new{
            blitbuffer = tile.bb,
            width = w,
            height = h,
            scale_factor = sf, -- 0: fit full page; 1: 1:1 for cropped viewport (and full-page tiles we pre-fit)
            center_x_ratio = 0.5,
            center_y_ratio = 0.5,
        }
    else
        logger.warn("KamareImageViewer: Failed to get BlitBuffer for page", current_page_num)
        -- Fallback to a placeholder
        self._image_wg = BlitBufferWidget:new{
            blitbuffer = Blitbuffer.new(max_image_w, max_image_h, Blitbuffer.TYPE_GRAY),
            width = max_image_w,
            height = max_image_h,
        }
        self._image_wg.blitbuffer:fill(Blitbuffer.COLOR_LIGHT_GRAY)
    end

    self.image_container = CenterContainer:new{
        dimen = Geom:new{
            w = self.width,
            h = self.img_container_h,
        },
        self._image_wg,
    }
end

function KamareImageViewer:onZoomIn(inc)
    self:_refreshScaleFactor()

    if not inc then
        inc = 0.2
    end

    local new_factor = self.scale_factor * (1 + inc)
    self:_applyNewScaleFactor(new_factor)
    return true
end

function KamareImageViewer:onZoomOut(dec)
    self:_refreshScaleFactor()

    if not dec then
        dec = 0.2
    elseif dec >= 0.75 then
        dec = 0.75
    end

    local new_factor = self.scale_factor * (1 - dec)
    self:_applyNewScaleFactor(new_factor)
    return true
end

function KamareImageViewer:_refreshScaleFactor()
    if self.scale_factor == 0 then
        -- If scale_factor is 0 (fit to screen), _scale_factor_0 holds the actual scale.
        -- If _image_wg is nil (e.g., during init before _new_image_wg is called),
        -- we can't get its scale, so rely on _scale_factor_0 if available.
        self.scale_factor = self._scale_factor_0 or (self._image_wg and self._image_wg:getScaleFactor()) or 1.0
    end
end

function KamareImageViewer:_applyNewScaleFactor(new_factor)
    self:_refreshScaleFactor()

    -- We need to get extrema from the current image's native dimensions
    local current_page_num = self._images_list_cur
    local native_dims = self.virtual_document:getNativePageDimensions(current_page_num)
    if not native_dims then
        logger.warn("KamareImageViewer: Cannot apply new scale factor, native dims not available.")
        return
    end

    local max_image_h = self.img_container_h
    local max_image_w = self.width
    if self.footer_visible or self.title_bar_visible then
        max_image_h = self.img_container_h - self.image_padding*2
        max_image_w = self.width - self.image_padding*2
    end

    -- Calculate min/max scale factors based on current image (account for rotation) and available space
    local w0, h0 = native_dims.w, native_dims.h
    local rotation_angle = self:_getRotationAngle()
    if rotation_angle == 90 or rotation_angle == 270 then
        w0, h0 = h0, w0
    end
    local min_scale_factor = math.min(max_image_w / w0, max_image_h / h0)
    local max_scale_factor = 4.0 -- Arbitrary max zoom, can be configurable

    new_factor = math.min(new_factor, max_scale_factor)
    new_factor = math.max(new_factor, min_scale_factor)

    if new_factor ~= self.scale_factor then
        self.scale_factor = new_factor
        self:updateImageOnly()
    end
end

function KamareImageViewer:onSpread(_, ges)
    if not self._image_wg then
        return
    end

    do
        local current_page_num = self._images_list_cur
        local native_dims = self.virtual_document:getNativePageDimensions(current_page_num)
        local rotation_angle = self:_getRotationAngle()
        local zoom = (self.scale_factor == 0) and (self._scale_factor_0 or 1.0) or self.scale_factor

        local vw = self.width
        local vh = self.img_container_h
        if self.footer_visible or self.title_bar_visible then
            vw = vw - self.image_padding*2
            vh = vh - self.image_padding*2
        end

        local page_size, viewport = self:_computeViewport(native_dims, zoom, rotation_angle, vw, vh)

        local dx = ges.pos.x - Screen:getWidth()/2
        local dy = ges.pos.y - Screen:getHeight()/2

        local cx = clamp(viewport.x + viewport.w/2 + dx, viewport.w/2, page_size.w - viewport.w/2)
        local cy = clamp(viewport.y + viewport.h/2 + dy, viewport.h/2, page_size.h - viewport.h/2)

        self._center_x_ratio = cx / page_size.w
        self._center_y_ratio = cy / page_size.h
    end
    -- We need to get the current rendered dimensions to calculate relative zoom
    local current_page_num = self._images_list_cur
    local native_dims = self.virtual_document:getNativePageDimensions(current_page_num)
    if not native_dims then return end

    local eff = self:_effectiveZoom()
    local current_rendered_w = native_dims.w * eff
    local current_rendered_h = native_dims.h * eff

    if ges.direction == "vertical" then
        local img_h = current_rendered_h
        local screen_h = Screen:getHeight()
        self:onZoomIn(ges.distance / math.min(screen_h, img_h))
    elseif ges.direction == "horizontal" then
        local img_w = current_rendered_w
        local screen_w = Screen:getWidth()
        self:onZoomIn(ges.distance / math.min(screen_w, img_w))
    else
        local img_d = math.sqrt(current_rendered_w^2 + current_rendered_h^2)
        local screen_d = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
        self:onZoomIn(ges.distance / math.min(screen_d, img_d))
    end
    return true
end

function KamareImageViewer:onPinch(_, ges)
    if not self._image_wg then
        return
    end

    -- We need to get the current rendered dimensions to calculate relative zoom
    local current_page_num = self._images_list_cur
    local native_dims = self.virtual_document:getNativePageDimensions(current_page_num)
    if not native_dims then return end

    local eff = self:_effectiveZoom()
    local current_rendered_w = native_dims.w * eff
    local current_rendered_h = native_dims.h * eff

    if ges.direction == "vertical" then
        local img_h = current_rendered_h
        local screen_h = Screen:getHeight()
        self:onZoomOut(ges.distance / math.min(screen_h, img_h))
    elseif ges.direction == "horizontal" then
        local img_w = current_rendered_w
        local screen_w = Screen:getWidth()
        self:onZoomOut(ges.distance / math.min(screen_w, img_w))
    else
        local img_d = math.sqrt(current_rendered_w^2 + current_rendered_h^2)
        local screen_d = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
        self:onZoomOut(ges.distance / math.min(screen_d, img_d))
    end
    return true
end

function KamareImageViewer:panBy(x, y)
    local current_page_num = self._images_list_cur
    local native_dims = self.virtual_document and self.virtual_document:getNativePageDimensions(current_page_num)
    if not native_dims then return end

    local rotation_angle = self:_getRotationAngle()
    local zoom = (self.scale_factor == 0) and (self._scale_factor_0 or 1.0) or self.scale_factor

    local vw = self.width
    local vh = self.img_container_h
    if self.footer_visible or self.title_bar_visible then
        vw = vw - self.image_padding*2
        vh = vh - self.image_padding*2
    end

    local page_size, viewport = self:_computeViewport(native_dims, zoom, rotation_angle, vw, vh)

    viewport.x = clamp(viewport.x + x, 0, math.max(0, page_size.w - viewport.w))
    viewport.y = clamp(viewport.y + y, 0, math.max(0, page_size.h - viewport.h))

    self._center_x_ratio = (viewport.x + viewport.w / 2) / page_size.w
    self._center_y_ratio = (viewport.y + viewport.h / 2) / page_size.h

    self:updateImageOnly()
end

function KamareImageViewer:onSwipe(_, ges)
    local direction = ges.direction
    local distance = ges.distance
    local sq_distance = math.sqrt(distance*distance/2)

    -- We need current rendered dimensions for zoom calculation
    local current_page_num = self._images_list_cur
    local native_dims = self.virtual_document:getNativePageDimensions(current_page_num)
    if not native_dims then return end
    local eff = self:_effectiveZoom()
    local current_rendered_h = native_dims.h * eff

    if direction == "north" then
        if ges.pos.x < Screen:getWidth() * 1/8 or ges.pos.x > Screen:getWidth() * 7/8 then
            local inc = ges.distance / math.min(Screen:getHeight(), current_rendered_h)
            self:onZoomIn(inc)
        else
            self:panBy(0, distance)
        end
    elseif direction == "south" then
        if ges.pos.x < Screen:getWidth() * 1/8 or ges.pos.x > Screen:getWidth() * 7/8 then
            local dec = ges.distance / math.min(Screen:getHeight(), current_rendered_h)
            self:onZoomOut(dec)
        elseif self.scale_factor == 0 then -- If fit to screen, swipe south closes
            self:onClose()
        else
            self:panBy(0, -distance)
        end
    elseif direction == "east" then
        self:panBy(-distance, 0)
    elseif direction == "west" then
        self:panBy(distance, 0)
    elseif direction == "northeast" then
        self:panBy(-sq_distance, sq_distance)
    elseif direction == "northwest" then
        self:panBy(sq_distance, sq_distance)
    elseif direction == "southeast" then
        self:panBy(-sq_distance, -sq_distance)
    elseif direction == "southwest" then
        self:panBy(sq_distance, -sq_distance)
    end
    return true
end

function KamareImageViewer:onHold(_, ges)
    self._panning = true
    self._pan_relative_x = ges.pos.x
    self._pan_relative_y = ges.pos.y
    return true
end

function KamareImageViewer:onHoldRelease(_, ges)
    if self._panning then
        self._panning = false
        self._pan_relative_x = ges.pos.x - self._pan_relative_x
        self._pan_relative_y = ges.pos.y - self._pan_relative_y
        if math.abs(self._pan_relative_x) < self.pan_threshold and math.abs(self._pan_relative_y) < self.pan_threshold then
            UIManager:setDirty(nil, "full", nil)
        else
            self:panBy(-self._pan_relative_x, -self._pan_relative_y)
        end
    end
    return true
end

function KamareImageViewer:onPan(_, ges)
    self._panning = true
    self._pan_relative_x = ges.relative.x
    self._pan_relative_y = ges.relative.y
    return true
end

function KamareImageViewer:onPanRelease(_, ges)
    if self._panning then
        self._panning = false
        self:panBy(-self._pan_relative_x, -self._pan_relative_y)
    end
    return true
end

function KamareImageViewer:onClose()
    if self.config_dialog then
        self.config_dialog:closeDialog()
    end

    self:syncAndSaveSettings()

    -- Ensure latest progress is saved (1-based page index)
    self:_postViewProgress()

    if self.title_bar_visible and self.title_bar then
        self.title_bar_visible = false
    end

    self:recordViewingTimeIfValid()

    if self.on_close_callback then
        self.on_close_callback(self._images_list_cur, self._images_list_nb)
    end

    -- Persist the most recently displayed full-page tile to disk
    if self.virtual_document and self.virtual_document.file then
        local ok, err = pcall(DocCache.serialize, DocCache, self.virtual_document.file)
        if not ok then
            logger.warn("DocCache serialize failed:", err)
        end
    end

    UIManager:close(self)
    return true
end

function KamareImageViewer:onCloseWidget()
    -- The BlitBufferWidget does not own the Blitbuffer, so no need to free self.image here.
    -- The VirtualImageDocument and its cache manage the Blitbuffers.

    if self.virtual_document then
        self.virtual_document:close()
        self.virtual_document = nil
    end

    -- _image_wg is now a BlitBufferWidget, its free() method is called by UIManager
    self._image_wg = nil

    if self.footer_text then
        self.footer_text:free()
    end
    if self.footer then
        self.footer:free()
    end
    if self.title_bar then
        self.title_bar:free()
    end

    UIManager:setDirty(nil, function()
        return "flashui", self.main_frame.dimen
    end)
end

return KamareImageViewer
