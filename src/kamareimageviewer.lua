local BD = require("ui/bidi")
local Device = require("device")
local KamareFooter = require("kamarefooter")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
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
local Size = require("ui/size")
local VirtualImageDocument = require("virtualimagedocument")
local VirtualPageCanvas = require("virtualpagecanvas")
local KavitaClient = require("kavitaclient")
local Math = require("optmath")
local GestureRange = require("ui/gesturerange")
local _ = require("gettext")
local T = require("ffi/util").template

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
            book_time_to_read = nil,
        }
    },

    images_list_data = nil,
    images_list_nb = nil,

    fullscreen = false,
    width = nil,
    height = nil,
    rotated = false,
    title = "",
    canvas = nil,
    canvas_container = nil,
    _images_list_cur = 1,

    on_close_callback = nil,
    start_page = 1,

    configurable = Configurable:new(),
    options = KamareOptions,
    prefetch_pages = 1,

    image_padding = Size.margin.small,

    virtual_document = nil,
    scroll_mode = true,
    scroll_offset = 0,
    current_zoom = 1.0,
    zoom_mode = 0, -- "full"
    _pending_scroll_page = nil,

    scroll_step_ratio = 0.25,

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
        progress_style_thick_height = 7,
        progress_margin_width = 10,
        items_separator = "bar",
        align = "center",
        lock_tap = false,
    },
}

------------------------------------------------------------------------
--  Initialisation & settings
------------------------------------------------------------------------

function KamareImageViewer:init()
    self:loadSettings()

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

    if not CanvasContext.device then
        CanvasContext:init(Device)
    end

    self:_initDocument()
    self:_initCanvas()

    self.align = "center"
    self.region = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    self:_updateDimensions()

    self:registerKeyEvents()
    self:setupTitleBar()
    self:initConfigGesListener()

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

    if self.scroll_mode then
        self._pending_scroll_page = self._images_list_cur
    end
    if self.virtual_document and self._images_list_nb > 1 then
        self.footer = KamareFooter:new{ owner = self }
        self.footer_visible = (self.footer_settings.mode ~= self.MODE.off)
    end

    self:update()

    UIManager:nextTick(function()
        self:prefetchUpcomingTiles()
        self:_postViewProgress()
    end)
end

function KamareImageViewer:_initDocument()
    local has_valid_images_data = true
    if not self.images_list_data then
        logger.err("KamareImageViewer: No images_list_data provided. Displaying empty screen.")
        has_valid_images_data = false
        self.images_list_data = { function() return nil end }
        self.images_list_nb = 1
    end

    local cache_id = (self.metadata and (self.title .. "/" .. self.metadata.seriesId .. "/" .. self.metadata.chapterId))
        or self.title or "session"

    self.virtual_document = VirtualImageDocument:new{
        images_list = self.images_list_data,
        images_dimensions = self.preloaded_dimensions,
        pages_override = self.images_list_nb,
        title = self.title,
        cache_id = cache_id,
        cache_mod_time = 0,
    }

    if not self.virtual_document.is_open then
        logger.err("KamareImageViewer: Failed to initialize VirtualImageDocument. Displaying empty screen.")
        self.is_open = true
    end

    self._images_list_nb = self.virtual_document:getPageCount()
    self._images_list_cur = Math.clamp((self.metadata and self.metadata.startPage) or 1, 1, self._images_list_nb)

    if has_valid_images_data and G_reader_settings:isTrue("imageviewer_rotate_auto_for_best_fit") then
        local dims = self.virtual_document:getNativePageDimensions(self._images_list_cur)
        if dims then
            self.rotated = (Screen:getWidth() > Screen:getHeight()) ~= (dims.w > dims.h)
        end
    end
end

function KamareImageViewer:_initCanvas()
    self.canvas = VirtualPageCanvas:new{
        document = self.virtual_document,
        padding = self.image_padding,
        background = Blitbuffer.COLOR_WHITE,
        scroll_mode = self.scroll_mode,
    }
end

function KamareImageViewer:_updateDimensions()
    if self.fullscreen then
        self.height = Screen:getHeight()
        self.width = Screen:getWidth()
    else
        self.height = Screen:getHeight() - Screen:scaleBySize(40)
        self.width = Screen:getWidth() - Screen:scaleBySize(40)
    end
end

------------------------------------------------------------------------
--  Settings
------------------------------------------------------------------------

function KamareImageViewer:getKamareSettings()
    if self.ui and self.ui.kamare and self.ui.kamare.kamare_settings then
        return self.ui.kamare.kamare_settings
    end

    local file = DataStorage:getSettingsDir() .. "/kamare.lua"
    local settings = LuaSettings:open(file)
    logger.info("KIV:getKamareSettings", "file", file, "has_data", next(settings.data) ~= nil, "data", settings.data)

    if next(settings.data) ~= nil then
        return settings
    end

    settings:close()
    return nil
end

function KamareImageViewer:loadSettings()
    local settings = self:getKamareSettings()

    logger.info("KIV:loadSettings enter", "has_settings", settings ~= nil)

    -- Preseed with current state; Configurable will overwrite if present
    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages
    self.configurable.scroll_mode = self.scroll_mode and 1 or 0
    self.configurable.zoom_mode_type = self.zoom_mode

    if settings then
        self.configurable:loadSettings(settings, self.options.prefix .. "_")
        logger.info("KIV:loadSettings raw",
            "footer_mode", self.configurable.footer_mode,
            "prefetch_pages", self.configurable.prefetch_pages,
            "scroll_mode", self.configurable.scroll_mode,
            "zoom_mode_type", self.configurable.zoom_mode_type)
    end

    self.footer_settings.mode = self.configurable.footer_mode
    self.prefetch_pages = self.configurable.prefetch_pages
    self.scroll_mode = (self.configurable.scroll_mode == 1)
    self.zoom_mode = self.configurable.zoom_mode_type

    logger.info("KIV:loadSettings applied",
        "footer_mode", self.footer_settings.mode,
        "prefetch_pages", self.prefetch_pages,
        "scroll_mode", self.scroll_mode,
        "zoom_mode", self.zoom_mode)

    logger.info("KIV:loadSettings resolved", "footer_mode", self.footer_settings.mode, "prefetch_pages", self.prefetch_pages, "scroll_mode", self.scroll_mode, "zoom_mode", self.zoom_mode)
end

function KamareImageViewer:syncAndSaveSettings()
    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages
    self.configurable.scroll_mode = self.scroll_mode and 1 or 0
    self.configurable.zoom_mode_type = self.zoom_mode

    self:saveSettings()
end

function KamareImageViewer:saveSettings()
    local settings = self:getKamareSettings()
    if settings then
        self.configurable:saveSettings(settings, self.options.prefix .. "_")
        settings:flush()
    end
end

function KamareImageViewer:getCurrentZoom()
    if self.canvas and self.canvas.zoom and self.canvas.zoom > 0 then
        return self.canvas.zoom
    end
    if self.canvas then
        self.canvas:setZoomMode(self.zoom_mode)
        if self.canvas.zoom and self.canvas.zoom > 0 then
            return self.canvas.zoom
        end
    end
    return self.current_zoom or 1.0
end

function KamareImageViewer:setZoomMode(mode)
    local changed = self.zoom_mode ~= mode
    if changed then
        self.zoom_mode = mode
        self._pending_scroll_page = self._images_list_cur
    end

    self.configurable.zoom_mode_type = self.zoom_mode
    self:syncAndSaveSettings()

    if changed then
        if self.canvas then
            self.canvas:setZoomMode(self.zoom_mode)
        end

        self:updateImageOnly()
        self:refreshFooter()

        UIManager:nextTick(function()
            self:prefetchUpcomingTiles()
        end)
    end

    return true
end

------------------------------------------------------------------------
--  UI setup
------------------------------------------------------------------------

function KamareImageViewer:registerKeyEvents()
    if not Device:hasKeys() then return end
    self.key_events = {
        Close         = { { Device.input.group.Back } },
        ShowPrevImage = { { Device.input.group.PgBack } },
        ShowNextImage = { { Device.input.group.PgFwd } },
    }
end

function KamareImageViewer:setupTitleBar()
    local title = self.title or _("Images")
    local subtitle

    if self.metadata then
        title = self.metadata.seriesName
            or self.metadata.localizedName
            or self.metadata.originalName
            or title
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
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
end


function KamareImageViewer:updateFooterTextGenerator()
    if self.footer then self.footer:updateTextGenerator() end
end


------------------------------------------------------------------------
--  Footer & progress
------------------------------------------------------------------------


function KamareImageViewer:refreshFooter()
    if self.footer then self.footer:refresh() end
end

function KamareImageViewer:updateProgressBar()
    if self.footer then self.footer:updateProgressBar() end
end

function KamareImageViewer:getTimeEstimate(remaining_images)
    if #self.image_viewing_times == 0 then return _("N/A") end
    local total = 0
    for _, t in ipairs(self.image_viewing_times) do total = total + t end
    local average = total / #self.image_viewing_times
    local remaining = remaining_images * average

    if remaining < 60 then
        return T(_("%1s"), math.ceil(remaining))
    elseif remaining < 3600 then
        return T(_("%1m"), math.ceil(remaining / 60))
    else
        local hours = math.floor(remaining / 3600)
        local minutes = math.ceil((remaining % 3600) / 60)
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

------------------------------------------------------------------------
--  Mode toggles, footer controls
------------------------------------------------------------------------

function KamareImageViewer:getCurrentFooterMode()
    return (self.footer and self.footer:getMode()) or self.footer_settings.mode
end

function KamareImageViewer:isValidMode(mode)
    return self.footer and self.footer:isValidMode(mode)
end

function KamareImageViewer:cycleToNextValidMode()
    if not self.footer then return self.footer_settings.mode end
    local mode = self.footer:cycleToNextValidMode()
    self.footer_settings.mode = mode
    self:syncAndSaveSettings()
    self:applyFooterMode()
    return mode
end

function KamareImageViewer:setFooterMode(mode)
    if not (self.footer and self.footer:isValidMode(mode)) then return false end
    self.footer_settings.mode = tonumber(mode) or self.footer_settings.mode
    self.footer:setMode(self.footer_settings.mode)
    self:syncAndSaveSettings()
    self:applyFooterMode()
    return true
end

function KamareImageViewer:initConfigGesListener()
    if not Device:isTouchDevice() then return end

    local DTAP_ZONE_MENU      = G_defaults:readSetting("DTAP_ZONE_MENU")
    local DTAP_ZONE_MENU_EXT  = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    local DTAP_ZONE_CONFIG    = G_defaults:readSetting("DTAP_ZONE_CONFIG")
    local DTAP_ZONE_CONFIG_EXT= G_defaults:readSetting("DTAP_ZONE_CONFIG_EXT")
    local DTAP_ZONE_MINIBAR   = G_defaults:readSetting("DTAP_ZONE_MINIBAR")
    local DTAP_ZONE_FORWARD   = G_defaults:readSetting("DTAP_ZONE_FORWARD")
    local DTAP_ZONE_BACKWARD  = G_defaults:readSetting("DTAP_ZONE_BACKWARD")

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

------------------------------------------------------------------------
--  Gesture callbacks
------------------------------------------------------------------------

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

function KamareImageViewer:onShowConfigMenu()
    self.configurable.footer_mode  = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages
    self.configurable.scroll_mode  = self.scroll_mode and 1 or 0
    self.configurable.zoom_mode_type = self.zoom_mode

    self.config_dialog = ConfigDialog:new{
        document = nil,
        ui = self.ui or self,
        configurable = self.configurable,
        config_options = self.options,
        is_always_active = true,
        covers_footer = true,
        close_callback = function() self:onConfigCloseCallback() end,
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

    if self.configurable.scroll_mode ~= nil then
        local new_scroll = tonumber(self.configurable.scroll_mode) == 1
        if new_scroll ~= self.scroll_mode then
            self.scroll_mode = new_scroll
            self._pending_scroll_page = self._images_list_cur
            if not self.scroll_mode then
                self.scroll_offset = 0
            end
            self:update()
        end
    end

    self:syncAndSaveSettings()
end

function KamareImageViewer:onCloseConfigMenu()
    if self.config_dialog then
        self.config_dialog:closeDialog()
    end
end

function KamareImageViewer:onSetFooterMode(mode)
    return self:setFooterMode(mode)
end

function KamareImageViewer:onSetPrefetchPages(value)
    local n = tonumber(value)
    if not n then return false end
    n = Math.clamp(n, 0, 3)
    if n == self.prefetch_pages then return true end
    self.prefetch_pages = n
    self.configurable.prefetch_pages = n
    self:syncAndSaveSettings()

    logger.dbg("KIV:onSet PrefetchPages", "n", n)

    UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
    return true
end

function KamareImageViewer:onSetScrollMode(value)
    local n = tonumber(value)
    local new_scroll = (n == 1)

    if new_scroll == self.scroll_mode then return true end

    self.scroll_mode = new_scroll
    self.configurable.scroll_mode = self.scroll_mode and 1 or 0
    self._pending_scroll_page = self._images_list_cur

    if not self.scroll_mode then
        self.scroll_offset = 0
    end

    self:syncAndSaveSettings()
    self:update()

    return true
end

function KamareImageViewer:onDefineZoom(mode)
    return self:setZoomMode(mode)
end

------------------------------------------------------------------------
--  Scroll helpers
------------------------------------------------------------------------

function KamareImageViewer:_clampScrollOffset(offset)
    if not self.canvas then return offset or 0 end
    local max_offset = self.canvas:getMaxScrollOffset() or 0
    return Math.clamp(offset or 0, 0, max_offset)
end

function KamareImageViewer:_setScrollOffset(offset, opts)
    if not self.scroll_mode then return end
    local clamped = self:_clampScrollOffset(offset)
    if math.abs(clamped - (self.scroll_offset or 0)) > 0.5 then
        self.scroll_offset = clamped
        if self.canvas then
            self.canvas:setScrollOffset(clamped)
        end
        self:_updatePageFromScroll(opts and opts.silent)
    end
end

function KamareImageViewer:_scrollBy(delta)
    self:_setScrollOffset((self.scroll_offset or 0) + delta)
end

function KamareImageViewer:_scrollStep(direction)
    if not (self.scroll_mode and self.canvas and self.virtual_document) then
        return false
    end

    local viewport_h = select(2, self.canvas:getViewportSize())
    if viewport_h <= 0 then
        return false
    end

    local zoom = self:getCurrentZoom()
    local step_ratio = self.scroll_step_ratio or 0.25
    local step = math.max(viewport_h * step_ratio, 1)
    local total = self.virtual_document:getVirtualHeight(zoom, self:_getRotationAngle()) or 0
    local offset = self.scroll_offset or 0

    if direction > 0 then
        if total > 0 and offset + step >= total - viewport_h then
            if self._images_list_cur < self._images_list_nb then
                self:switchToImageNum(self._images_list_cur + 1)
            else
                self:_setScrollOffset(math.max(0, total - viewport_h))
            end
        else
            self:_scrollBy(step)
        end
        return true
    elseif direction < 0 then
        if offset - step <= 0 then
            if self._images_list_cur > 1 then
                self:switchToImageNum(self._images_list_cur - 1)
            else
                self:_setScrollOffset(0)
            end
        else
            self:_scrollBy(-step)
        end
        return true
    end

    return false
end

function KamareImageViewer:_scrollToPage(page)
    if not self.scroll_mode or not self.virtual_document then return end
    local zoom = self:getCurrentZoom()
    local offset = self.virtual_document:getScrollPositionForPage(page, zoom, self:_getRotationAngle())
    self:_setScrollOffset(offset, { silent = true })
    self:_updatePageFromScroll(true)
    self:updateProgressBar()
    self:refreshFooter()
end

function KamareImageViewer:_updatePageFromScroll(silent)
    if not self.scroll_mode or not self.virtual_document then return end
    local zoom = self:getCurrentZoom()
    local new_page = self.virtual_document:getPageAtOffset(self.scroll_offset or 0, zoom, self:_getRotationAngle())
    if new_page ~= self._images_list_cur then
        if not silent then self:recordViewingTimeIfValid() end
        self._images_list_cur = new_page
        self.current_image_start_time = os.time()
        self:updateFooterTextGenerator()
        self:refreshFooter()
        self:_postViewProgress()
        UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
    elseif not silent then
        self:refreshFooter()
    end
end

------------------------------------------------------------------------
--  Canvas update & rendering
------------------------------------------------------------------------

function KamareImageViewer:_ensureCanvas()
    if not self.canvas then
        self.canvas = VirtualPageCanvas:new{
            document = self.virtual_document,
            padding = self.image_padding,
            background = Blitbuffer.COLOR_WHITE,
        }
    else
        self.canvas:setDocument(self.virtual_document)
        self.canvas:setPadding(self.image_padding)
        self.canvas:setBackground(Blitbuffer.COLOR_WHITE)
    end

    if not self.canvas_container then
        self.canvas_container = CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.img_container_h },
            self.canvas,
        }
    else
        self.canvas_container.dimen = Geom:new{ w = self.width, h = self.img_container_h }
        self.canvas_container[1] = self.canvas
    end

    self.image_container = self.canvas_container
end

function KamareImageViewer:_updateCanvasState()
    if not (self.canvas and self.virtual_document) then return end

    local page = Math.clamp(self._images_list_cur or 1, 1, self._images_list_nb or 1)
    local rotation = self:_getRotationAngle()

    self.canvas:setMode(self.scroll_mode and "scroll" or "page")
    self.canvas:setRotation(rotation)
    self.canvas:setZoomMode(self.zoom_mode)
    self.canvas:setPage(page)
    self.canvas:setSize{
        w = math.max(1, self.width),
        h = math.max(1, self.img_container_h or self.height or Screen:getHeight()),
    }

    local need_layout_refresh = self.canvas._layout_dirty
    if not need_layout_refresh then
        need_layout_refresh = not (self.canvas.zoom and self.canvas.zoom > 0)
    end

    if need_layout_refresh
        and self.canvas.recalculateLayout
        and self.canvas.dimen
        and self.canvas.dimen.w > 0
        and self.canvas.dimen.h > 0 then
        local ok, err = pcall(function()
            self.canvas:recalculateLayout()
        end)
        if not ok then
            logger.warn("KamareImageViewer:_updateCanvasState recalc failed", err)
        end
    end

    self.current_zoom = self.canvas.zoom or 1.0

    if self.scroll_mode then
        local desired = self.scroll_offset or 0
        if self._pending_scroll_page then
            desired = self.virtual_document:getScrollPositionForPage(self._pending_scroll_page, self.current_zoom, rotation)
            self._pending_scroll_page = nil
        end
        desired = self:_clampScrollOffset(desired)
        self.scroll_offset = desired
        self.canvas:setScrollOffset(desired)
        self:_updatePageFromScroll(true)
        self:updateProgressBar()
    else
        self.scroll_offset = 0
        self.canvas:setCenter(0.5, 0.5)
        self:updateProgressBar()
    end
end

function KamareImageViewer:update()
    local orig = self.main_frame.dimen

    self:_updateDimensions()
    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    if self.title_bar_visible and self.title_bar then
        table.insert(self.frame_elements, self.title_bar)
    end
    local image_idx = #self.frame_elements + 1
    if self.footer and self.footer_visible then
        self.footer:update()
        table.insert(self.frame_elements, self.footer:getWidget())
    end
    self.img_container_h = self.height - self.frame_elements:getSize().h

    self:_ensureCanvas()
    self:_updateCanvasState()

    if self.image_container then
        table.insert(self.frame_elements, image_idx, self.image_container)
    end
    self.frame_elements:resetLayout()

    self.main_frame.radius = not self.fullscreen and 8 or nil

    UIManager:setDirty(self, function()
        local region = self.main_frame.dimen:combine(orig)
        return "partial", region
    end)
end

function KamareImageViewer:updateImageOnly()
    if not self.canvas then return self:update() end
    self:_updateCanvasState()
end

------------------------------------------------------------------------
--  Prefetching
------------------------------------------------------------------------

function KamareImageViewer:prefetchUpcomingTiles()
    if not self.virtual_document then return end
    local count = tonumber(self.prefetch_pages) or 0
    if count <= 0 then return end

    local zoom = self:getCurrentZoom()
    local pages = {}

    if self.scroll_mode and self.canvas then
        local viewport_h = select(2, self.canvas:getViewportSize())
        local visible = self.virtual_document:getVisiblePagesAtOffset(self.scroll_offset or 0, viewport_h, zoom, self:_getRotationAngle()) or {}
        local last = self._images_list_cur
        if #visible > 0 then
            last = visible[#visible].page_num
        end
        for i = 1, count do
            table.insert(pages, last + i)
        end
    else
        for i = 1, count do
            table.insert(pages, (self._images_list_cur or 0) + i)
        end
    end

    for _, page in ipairs(pages) do
        if page >= 1 and page <= (self._images_list_nb or 0) then
            UIManager:nextTick(function()
                pcall(function()
                    self.virtual_document:prefetchPage(page, zoom, self:_getRotationAngle())
                end)
            end)
        end
    end
end

------------------------------------------------------------------------
--  Gestures: scrolling
------------------------------------------------------------------------

function KamareImageViewer:onSwipe(_, ges)
    local dir = ges.direction
    local dist = ges.distance

    if dir == "north" then
        if self.scroll_mode then
            self:_scrollBy(dist)
        end
    elseif dir == "south" then
        if self.scroll_mode then
            self:_scrollBy(-dist)
        elseif self.scale_factor == 0 then
            self:onClose()
        end
    end
    return true
end

------------------------------------------------------------------------
--  Page navigation & closing
------------------------------------------------------------------------

function KamareImageViewer:switchToImageNum(page)
    self:recordViewingTimeIfValid()
    page = Math.clamp(page, 1, self._images_list_nb)
    if page == self._images_list_cur then return end

    self._images_list_cur = page
    self.current_image_start_time = os.time()

    if self.scroll_mode then
        self:_scrollToPage(page)
    else
        self.scroll_offset = 0
    end

    self:updateImageOnly()
    self:refreshFooter()
    self:_postViewProgress()
    UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
end

function KamareImageViewer:onShowNextImage()
    if self.scroll_mode and self:_scrollStep(1) then
        return
    end
    if self._images_list_cur < self._images_list_nb then
        self:switchToImageNum(self._images_list_cur + 1)
    end
end

function KamareImageViewer:onShowPrevImage()
    if self.scroll_mode and self:_scrollStep(-1) then
        return
    end
    if self._images_list_cur > 1 then
        self:switchToImageNum(self._images_list_cur - 1)
    end
end

function KamareImageViewer:onShowNextSlice()
    if not self.scroll_mode then
        self:onShowNextImage()
        return
    end
    self:_scrollStep(1)
end

function KamareImageViewer:onShowPrevSlice()
    if not self.scroll_mode then
        self:onShowPrevImage()
        return
    end
    self:_scrollStep(-1)
end

------------------------------------------------------------------------
--  Prefetch progress reporting
------------------------------------------------------------------------

function KamareImageViewer:_postViewProgress()
    if not (self.metadata and KavitaClient and KavitaClient.bearer) then return end
    if self.last_posted_page == self._images_list_cur then return end
    local page1 = self._images_list_cur
    UIManager:nextTick(function()
        pcall(function()
            KavitaClient:postReaderProgressForPage(self.metadata, page1)
        end)
    end)
    self.last_posted_page = page1
end

------------------------------------------------------------------------
--  Close handling
------------------------------------------------------------------------

function KamareImageViewer:onClose()
    if self.config_dialog then
        self.config_dialog:closeDialog()
    end

    self:syncAndSaveSettings()
    self:_postViewProgress()
    self:recordViewingTimeIfValid()

    if self.title_bar_visible then
        self.title_bar_visible = false
    end

    if self.on_close_callback then
        self.on_close_callback(self._images_list_cur, self._images_list_nb)
    end

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
    if self.virtual_document then
        self.virtual_document:close()
        self.virtual_document = nil
    end

    if self.canvas then
        self.canvas:setDocument(nil)
        self.canvas = nil
    end
    self.canvas_container = nil

    if self.footer then self.footer:free() end
    if self.title_bar then self.title_bar:free() end

    UIManager:setDirty(nil, function()
        return "flashui", self.main_frame.dimen
    end)
end

function KamareImageViewer:_getRotationAngle()
    return self.rotated and 90 or 0
end

function KamareImageViewer:toggleTitleBar()
    self.title_bar_visible = not self.title_bar_visible
    self:update()
end

function KamareImageViewer:applyFooterMode()
    self.footer_visible = (self.footer_settings.mode ~= self.MODE.off)
    self:updateFooterTextGenerator()
    self:update()
end

return KamareImageViewer
