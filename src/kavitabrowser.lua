local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local KavitaClient = require("kavitaclient")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local KamareImageViewer = require("kamareimageviewer")
local _ = require("gettext")
local T = ffiUtil.template

-- Progress indicator for read status
local function progress_icon(read, total)
    if type(read) ~= "number" or type(total) ~= "number" or total <= 0 then return nil end
    if read <= 0 then return "○" end -- 0%
    local r = read / total
    if r >= 1.0 then return "●" end -- 100%
    if r > 0.5 then return "◕" end  -- >50%–<100%
    if r > 0.25 then return "◑" end -- >25%–<=50%
    return "◔"                      -- >0%–<=25%
end


local KavitaBrowser = Menu:extend{
    title_shrink_font_to_fit = true,
    -- CoverBrowser integration (set via new() parameters)
    has_coverbrowser = false,
    BookInfoManager = nil,
    CoverMenu = nil,
    ListMenu = nil,
    MosaicMenu = nil,
}

function KavitaBrowser:init()
    self.paths = self.paths or {}

    local is_initial_browser_startup = not self.has_initialized_before
    self.has_initialized_before = true

    if is_initial_browser_startup and self.servers and #self.servers == 1 then
        local single_server = self.servers[1]
        -- First set up basic properties
        self.item_table = {}
        self.catalog_title = nil
        self.title_bar_left_icon = "appbar.menu"
        self.onLeftButtonTap = function()
            self:showTitleMenu()
        end

        -- Apply CoverBrowser enhancements if available (BEFORE Menu.init)
        if self.has_coverbrowser then
            self:_applyCoverBrowserEnhancements()
        else
            logger.warn("Kamare: CoverBrowser not available")
        end

        -- NOW initialize Menu (after CoverBrowser methods are in place)
        Menu.init(self)

        -- Then load the server's content
        self.current_server_name = single_server.name
        self:authenticateAfterSelection(single_server.name, single_server.url)
        self:showDashboardAfterSelection(single_server.name)

        return
    end

    -- Normal behavior for multiple servers or no servers
    self.item_table = self:genItemTableFromRoot()
    self.catalog_title = nil
    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end

    Menu.init(self)

    -- Apply CoverBrowser enhancements if available
    if self.has_coverbrowser then
        self:_applyCoverBrowserEnhancements()
    else
        logger.warn("Kamare: CoverBrowser not available")
    end
end

function KavitaBrowser:_applyCoverBrowserEnhancements()
    -- Read display mode from CoverBrowser's global FileManager setting
    local display_mode = self.BookInfoManager:getSetting("filemanager_display_mode")

    -- Extract display mode type: "mosaic" or "list"
    local display_mode_type = display_mode and display_mode:gsub("_.*", "") or nil

    -- Only apply CoverBrowser enhancements if not in classic mode
    if not display_mode or display_mode == "" then
        logger.warn("Kamare: Classic mode detected, skipping CoverBrowser enhancements")
        return
    end

    -- Override methods on this instance (same pattern as CoverBrowser does for History/Collections)
    -- Wrap updateItems to force recalculation when page_num is wrong
    local original_updateItems = self.CoverMenu.updateItems
    self.updateItems = function(cover_menu_self, select_number, no_recalculate_dimen)
        -- Force recalculation if page_num doesn't match expected value
        if cover_menu_self.item_table and #cover_menu_self.item_table > 0 and cover_menu_self.perpage and cover_menu_self.perpage > 0 then
            local expected_page_num = math.ceil(#cover_menu_self.item_table / cover_menu_self.perpage)
            if cover_menu_self.page_num ~= expected_page_num then
                no_recalculate_dimen = false
            end
        end

        return original_updateItems(cover_menu_self, select_number, no_recalculate_dimen)
    end

    -- Wrap onCloseWidget to call CoverBrowser's cleanup
    local original_onCloseWidget = self.CoverMenu.onCloseWidget
    self.onCloseWidget = function()
        if original_onCloseWidget then
            original_onCloseWidget(self)
        end
    end

    -- Initialize grid dimensions (same as CoverBrowser.initGrid)
    self.nb_cols_portrait = self.BookInfoManager:getSetting("nb_cols_portrait") or 3
    self.nb_rows_portrait = self.BookInfoManager:getSetting("nb_rows_portrait") or 3
    self.nb_cols_landscape = self.BookInfoManager:getSetting("nb_cols_landscape") or 4
    self.nb_rows_landscape = self.BookInfoManager:getSetting("nb_rows_landscape") or 2
    self.files_per_page = self.BookInfoManager:getSetting("files_per_page") or 8

    self.display_mode_type = display_mode_type

    if self.display_mode_type == "mosaic" then
        -- Replace methods with MosaicMenu versions
        local original_mosaic_recalculate = self.MosaicMenu._recalculateDimen
        self._recalculateDimen = function(...)
            local result = original_mosaic_recalculate(self, ...)

            -- Fix: MosaicMenu calculates page_num = 0 for empty tables, but base Menu returns 1
            self.page_num = math.max(1, self.page_num or 0)

            return result
        end
        self._updateItemsBuildUI = self.MosaicMenu._updateItemsBuildUI

        -- Set MosaicMenu behavior flags
        self._do_cover_images = display_mode ~= "mosaic_text"
        self._do_center_partial_rows = true

    elseif self.display_mode_type == "list" then
        -- Replace methods with ListMenu versions
        local original_listmenu_recalculate = self.ListMenu._recalculateDimen
        self._recalculateDimen = function(...)
            local result = original_listmenu_recalculate(self, ...)

            -- Fix: ListMenu calculates page_num = 0 for empty tables, but base Menu returns 1
            self.page_num = math.max(1, self.page_num or 0)

            return result
        end
        self._updateItemsBuildUI = self.ListMenu._updateItemsBuildUI

        -- Set ListMenu behavior flags
        self._do_cover_images = display_mode ~= "list_only_meta"
        self._do_filename_only = display_mode == "list_image_filename"
    else
        logger.error("Kamare: Unknown display_mode_type - neither mosaic nor list!")
        logger.error("Kamare: This will cause crashes - _recalculateDimen not set")
    end

    -- Disable hint for opened books (we don't track that for Kavita)
    self._do_hint_opened = false

    -- Set up getBookInfo as a function (not method) that CoverBrowser can call
    -- CoverBrowser calls menu.getBookInfo(filepath), not menu:getBookInfo(filepath)
    -- CoverBrowser expects this to ALWAYS return a table, never nil
    self.getBookInfo = function(filepath)
        -- Start with BookInfoManager data (static metadata like title, authors, pages)
        local bookinfo = self.BookInfoManager:getBookInfo(filepath)

        -- For Kavita virtual paths, enhance with live progress from item_table
        if filepath and filepath:match("^/kavita/") then
            -- Find the matching item in item_table
            local kavita_item = nil
            if self.item_table then
                for _, item in ipairs(self.item_table) do
                    if item.file == filepath then
                        kavita_item = item
                        break
                    end
                end
            end

            -- Extract progress from Kavita DTO (series, volume, or chapter)
            local pagesRead, pages = nil, nil
            if kavita_item then
                -- Check for series first (for stream lists like On Deck, Recently Updated, etc.)
                if kavita_item.series then
                    pagesRead = kavita_item.series.pagesRead or kavita_item.series.pageRead
                    pages = kavita_item.series.pages
                elseif kavita_item.volume then
                    pagesRead = kavita_item.volume.pagesRead or kavita_item.volume.pageRead
                    pages = kavita_item.volume.pages
                elseif kavita_item.chapter then
                    pagesRead = kavita_item.chapter.pagesRead or kavita_item.chapter.pageRead
                    pages = kavita_item.chapter.pages
                end
            end

            -- Fallback: use bookinfo pages if DTO doesn't have it
            if not pages and bookinfo and bookinfo.pages then
                pages = bookinfo.pages
            end

            -- Calculate percent_finished
            local percent_finished = nil
            if pagesRead and pages and pages > 0 then
                percent_finished = pagesRead / pages
            end

            -- Determine status
            local status = nil
            if pagesRead and pages and pagesRead >= pages then
                status = "complete"
            end

            -- Build the complete book_info structure
            local result = bookinfo or {}
            result.been_opened = (pagesRead and pagesRead > 0) or false
            result.pages = pages  -- Use calculated pages (DTO or BookInfoManager)
            result.percent_finished = percent_finished
            result.status = status
            result.has_annotations = false

            return result
        end

        -- For regular files, return BookInfoManager data
        if bookinfo then
            return bookinfo
        end

        -- Fallback: always return a valid table (never nil!)
        return { been_opened = false }
    end

    -- Mark as CoverBrowser-enhanced
    self._coverbrowser_overridden = true
end

function KavitaBrowser:showTitleMenu()
    local dialog
    local buttons = {}

    -- Only show Search when inside a server (i.e., not at root)
    if self.paths and #self.paths > 0 then
        table.insert(buttons, {{
            text = _("Search"),
            callback = function()
                UIManager:close(dialog)
                self:showKavitaSearchDialog()
            end,
            align = "left",
        }})
    end

    table.insert(buttons, {{
        text = _("Add Kavita server"),
        callback = function()
            UIManager:close(dialog)
            self:addEditServer(nil, false)
        end,
        align = "left",
    }})

    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

-- Build menu entries from the Kavita dashboard array
function KavitaBrowser:buildKavitaDashboardItems(dashboard)
    local items = {}
    if type(dashboard) == "table" then
        for _, d in ipairs(dashboard) do
            local original_name = d.name or ""
            -- Map to actual API stream names
            local api_name = original_name
            if api_name == "recently-updated" then
                api_name = "recently-updated-series"
            elseif api_name == "newly-added" or api_name == "recently-added" then
                api_name = "recently-added-v2"
            end

            -- Human-readable labels
            local name = original_name
            if name == "on-deck" then
                name = "On Deck"
            elseif name == "recently-updated" or name == "recently-updated-series" then
                name = "Recently Updated"
            elseif name == "newly-added" or name == "recently-added" or name == "recently-added-v2" then
                name = "Newly Added"
            elseif name == "want-to-read" then
                name = "Want to Read"
            elseif name == "" then
                name = _("Unnamed")
            end

            local item = {
                text = name,
                kavita_dashboard = true,
                kavita_stream_name = api_name,
                dashboard = d, -- keep full dto for future navigation
            }

            -- Dashboard items are folders/streams, not files
            -- CoverBrowser needs a path even for directories
            if self.has_coverbrowser then
                item.is_file = false  -- Mark as directory
                -- Provide a dummy directory path
                item.path = string.format("/kavita/%s/stream/%s/",
                    self.current_server_name or "unknown", api_name)
            end

            table.insert(items, item)
        end
    end

    -- Manually add "Want to Read" after the dashboard items
    local item = {
        text = "Want to Read",
        kavita_dashboard = true,
        kavita_stream_name = "want-to-read",
        dashboard = { name = "want-to-read" },
    }
    if self.has_coverbrowser then
        item.is_file = false  -- Mark as directory
        -- Provide a dummy directory path
        item.path = string.format("/kavita/%s/stream/want-to-read/",
            self.current_server_name or "unknown")
    end
    table.insert(items, item)

    return items
end

-- Fetch dashboard and display it as the server root list
function KavitaBrowser:showDashboardAfterSelection(server_name)
    local loading = InfoMessage:new{ text = _("Loading..."), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local data, code, __, status = KavitaClient:getDashboard()

    UIManager:close(loading)

    if not data then
        self:handleCatalogError("dashboard", "/api/Stream/dashboard", status or code)
        return
    end

    local items = self:buildKavitaDashboardItems(data)
    self.catalog_title = server_name
    self.search_url = nil

    -- Rebase the stack on the dashboard so Back goes: Stream -> Dashboard -> Servers
    self.paths = { { kavita_dashboard_root = true, title = server_name } }

    self:switchItemTable(self.catalog_title, items, nil, nil, nil)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

function KavitaBrowser:showKavitaSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Kavita"),
        input_hint = _("Enter title, author, tag…"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local q = dialog:getInputText()
                        UIManager:close(dialog)
                        if not q or q == "" then
                            UIManager:show(InfoMessage:new{ text = _("Empty search") })
                            return
                        end
                        self:performKavitaSearch(q)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KavitaBrowser:performKavitaSearch(query)
    local loading = InfoMessage:new{ text = _("Searching…"), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local result, code, __, status = KavitaClient:getSearch(query, false)

    UIManager:close(loading)

    if not result then
        self:handleCatalogError("search", "/api/Search/search", status or code)
        return
    end

    local series_hits = result.series or {}
    local normalized = {}
    for _, hit in ipairs(series_hits) do
        local s = hit.series or hit
        table.insert(normalized, s)
    end

    local items = self:buildKavitaSeriesItems(normalized or {})
    self.catalog_title = _("Search results")
    self.catalog_author = string.format("%s", query)
    self.search_url = nil

    if not items or #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No results") })
    end
    self:switchItemTable(self.catalog_title, items, nil, nil, self.catalog_author)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Build menu entries from a list of SeriesDto
function KavitaBrowser:buildKavitaSeriesItems(series_list)
    local items = {}
    if type(series_list) == "table" then
        for i, s in ipairs(series_list) do
            local name = s.localizedName or s.name or s.originalName or s.seriesName or s.title or _("Unnamed series")
            -- Note: SeriesDto doesn't include author/writer info. That's only available
            -- in SeriesDetailDto via chapters. To avoid showing library name as "author",
            -- we leave it empty for series lists.
            local mandatory = progress_icon(s.pagesRead, s.pages)
            local item = {
                text = name,
                author = "",  -- Empty - SeriesDto doesn't have author fields
                mandatory = self.has_coverbrowser and nil or (mandatory or ""),
                kavita_series = true,
                series = s, -- keep full dto for next steps
            }

            -- Add virtual filepath (always set to prevent CoverBrowser crashes)
            if s.id then
                item.file = string.format("/kavita/%s/series/%d.kavita",
                                         self.current_server_name or "unknown",
                                         s.id)
                item.is_file = true
            end

            table.insert(items, item)
        end
    end
    return items
end

-- Build menu entries for VolumeDto[]
function KavitaBrowser:buildKavitaVolumeItems(volumes)
    local items = {}
    if type(volumes) == "table" then
        for _, v in ipairs(volumes) do
            local vol_prefix = v.number and ("Volume " .. tostring(v.number)) or nil
            local name
            if v.name and v.name ~= "" then
                local lower = v.name:lower()
                if not (lower:find("vol") or lower:find("volume")) and vol_prefix then
                    name = vol_prefix .. ": " .. v.name
                else
                    name = v.name
                end
            else
                name = vol_prefix or ("Volume #" .. tostring(v.id or "?"))
            end
            local read = v.pagesRead or v.pageRead
            local total = v.pages
            local subtitle = (total and read) and (tostring(read) .. "/" .. tostring(total) .. " pages") or nil
            local mandatory = progress_icon(read, total)
            local item = {
                text = name,
                author = subtitle,
                mandatory = self.has_coverbrowser and nil or mandatory,
                kavita_volume = true,
                volume = v,
            }

            -- Add virtual filepath (always set to prevent CoverBrowser crashes)
            if v.id then
                item.file = string.format("/kavita/%s/volume/%d.kavita",
                                         self.current_server_name or "unknown",
                                         v.id)
                item.is_file = true
            end

            table.insert(items, item)
        end
    end
    return items
end

-- Build menu entries for ChapterDto[]
function KavitaBrowser:buildKavitaChapterItems(chapters, kind)
    local items = {}
    if type(chapters) == "table" then
        for i, c in ipairs(chapters) do
            local ch_prefix = c.number and ("Ch. " .. tostring(c.number)) or nil
            local base
            if c.titleName and c.titleName ~= "" then
                local lower = c.titleName:lower()
                if not (lower:find("ch") or lower:find("chap") or lower:find("chapter") or lower:find("vol") or lower:find("volume")) and ch_prefix then
                    base = ch_prefix .. ": " .. c.titleName
                else
                    base = c.titleName
                end
            else
                base = c.title or c.range or ch_prefix or ("Chapter #" .. tostring(c.id or "?"))
            end
            local name = (kind == "special") and (_("Special") .. ": " .. base) or base

            local read = c.pagesRead or c.pageRead
            local total = c.pages
            local subtitle
            if total and read then
                subtitle = tostring(read) .. "/" .. tostring(total) .. " pages"
            end

            local mandatory = progress_icon(read, total)

            local item = {
                text = name,
                author = subtitle,
                mandatory = self.has_coverbrowser and nil or mandatory,
                kavita_chapter = true,
                chapter = c,
                is_special = (kind == "special") or nil,
            }

            -- Add virtual filepath (always set to prevent CoverBrowser crashes)
            if c.id then
                item.file = string.format("/kavita/%s/chapter/%d.kavita",
                                         self.current_server_name or "unknown",
                                         c.id)
                item.is_file = true
            end

            table.insert(items, item)
        end
    end
    return items
end

-- Fetch SeriesDetail and display Volumes, then Chapters, then Specials
function KavitaBrowser:showSeriesDetail(series_name, series_id, library_id, opts)
    local loading = InfoMessage:new{ text = _("Loading..."), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local detail, code, __, status = KavitaClient:getSeriesDetail(series_id)

    UIManager:close(loading)

    -- Track series context for reader progress (requires seriesId and libraryId)
    self.current_series_id = series_id
    self.current_series_library_id = library_id
    if not self.current_series_library_id then
        local series = KavitaClient:getSeriesById(series_id)
        if type(series) == "table" and series.libraryId then
            self.current_series_library_id = series.libraryId
        end
    end

    if not detail then
        self:handleCatalogError("series", "/api/Series/series-detail?seriesId=" .. tostring(series_id), status or code)
        return
    end

    local items = {}
    for _, it in ipairs(self:buildKavitaVolumeItems(detail.volumes or {})) do table.insert(items, it) end
    for _, it in ipairs(self:buildKavitaChapterItems(detail.chapters or {}, "chapter")) do table.insert(items, it) end
    for _, it in ipairs(self:buildKavitaChapterItems(detail.specials or {}, "special")) do table.insert(items, it) end

    self.catalog_title = series_name or _("Series")
    self.search_url = nil

    -- Derive subtitle from writers of the first available item (prefer first volume's first chapter)
    local function extractWritersFromChapter(ch)
        local names = {}
        if ch and type(ch.writers) == "table" then
            for _, p in ipairs(ch.writers) do
                if type(p) == "table" and p.name then
                    table.insert(names, p.name)
                elseif type(p) == "string" then
                    table.insert(names, p)
                end
            end
        end
        if #names > 0 then
            return table.concat(names, ", ")
        end
    end
    local subtitle
    if detail.volumes and type(detail.volumes) == "table" and detail.volumes[1] then
        local v = detail.volumes[1]
        if v.chapters and type(v.chapters) == "table" and v.chapters[1] then
            subtitle = extractWritersFromChapter(v.chapters[1])
        end
    end
    if not subtitle and detail.chapters and type(detail.chapters) == "table" and detail.chapters[1] then
        subtitle = extractWritersFromChapter(detail.chapters[1])
    end
    if not subtitle and detail.specials and type(detail.specials) == "table" and detail.specials[1] then
        subtitle = extractWritersFromChapter(detail.specials[1])
    end
    self.catalog_author = subtitle
    -- Keep series naming/author for the reader overlay
    self.current_series_names = self.current_series_names or { name = self.catalog_title }
    if not self.current_series_names.author and subtitle then
        self.current_series_names.author = subtitle
    end
    -- Try to enrich names from detail if present
    if type(detail) == "table" then
        local orig = detail.originalName or (detail.series and detail.series.originalName)
        local loc  = detail.localizedName or (detail.series and detail.series.localizedName)
        local nm   = detail.name or (detail.series and detail.series.name)
        if orig and not self.current_series_names.originalName then self.current_series_names.originalName = orig end
        if loc and not self.current_series_names.localizedName then self.current_series_names.localizedName = loc end
        if nm and not self.current_series_names.name then self.current_series_names.name = nm end
    end

    local refresh_only = opts and opts.refresh_only
    -- Push a sentinel so back returns to the stream list (skip when refreshing)
    if not refresh_only then
        self.paths = self.paths or {}
        table.insert(self.paths, { kavita_stream_root = self.current_stream_name, title = self.catalog_title })
    end

    -- Pass -1 to maintain current page when refreshing, nil to reset to page 1
    local itemnumber = refresh_only and -1 or nil
    self:switchItemTable(self.catalog_title, items, itemnumber, nil, self.catalog_author)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Fetch a specific Kavita stream (e.g., on-deck) and display series
function KavitaBrowser:showKavitaStream(stream_name)
    local loading = InfoMessage:new{ text = _("Loading..."), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    -- Determine pagination strategy based on stream type
    local max_pages
    if stream_name == "on-deck" or stream_name == "want-to-read" then
        max_pages = nil  -- Fetch all pages for on-deck and want-to-read
    else
        max_pages = 1  -- Limit to 1 page for all other streams
    end

    -- Fetch all pages until we get less than page_size results or empty results
    local all_data = {}
    local page_num = 1
    local page_size = 50
    local has_more = true

    while has_more do
        local data, code, __, status = KavitaClient:getStreamSeries(stream_name, { PageNumber = page_num, PageSize = page_size })

        if not data then
            UIManager:close(loading)
            self:handleCatalogError("stream", "/api/Stream/" .. tostring(stream_name), status or code)
            return
        end

        -- Append results to all_data
        if type(data) == "table" and #data > 0 then
            for _, item in ipairs(data) do
                table.insert(all_data, item)
            end

            -- Check if we should continue fetching
            if #data < page_size then
                has_more = false
            elseif max_pages and page_num >= max_pages then
                has_more = false  -- Reached max page limit
            else
                page_num = page_num + 1
            end
        else
            has_more = false
        end
    end

    UIManager:close(loading)

    local data = all_data

    -- Normalize response to a flat array of SeriesDto
    local series_list = data
    if type(data) == "table" and #data == 0 then
        series_list = data.items or data.series or data.data or data.results or data.entries
        if type(series_list) ~= "table" then
            local tmp = {}
            for _, v in pairs(data) do
                if type(v) == "table" then
                    if v.id and (v.name or v.localizedName or v.originalName) then
                        table.insert(tmp, v)
                    elseif type(v[1]) == "table" then
                        for __, vv in ipairs(v) do
                            if type(vv) == "table" and (vv.name or vv.localizedName or vv.originalName) then
                                table.insert(tmp, vv)
                            end
                        end
                    end
                end
            end
            series_list = tmp
        end
    end

    local items = self:buildKavitaSeriesItems(series_list or {})

    -- Remember current stream for back navigation from series detail
    self.current_stream_name = stream_name

    local title = stream_name
    if stream_name == "on-deck" then
        title = _("On Deck")
    elseif stream_name == "recently-updated" or stream_name == "recently-updated-series" then
        title = _("Recently Updated")
    elseif stream_name == "newly-added" or stream_name == "recently-added-v2" then
        title = _("Newly Added")
    elseif stream_name == "want-to-read" then
        title = _("Want to Read")
    end

    self.catalog_title = title
    self.search_url = nil

    -- Push a stream sentinel so back returns to dashboard
    self.paths = self.paths or {}
    local top = self.paths[#self.paths]
    if not (top and top.kavita_stream_root == stream_name) then
        table.insert(self.paths, { kavita_stream_root = stream_name, title = self.catalog_title })
    end

    self:switchItemTable(self.catalog_title, items, nil, nil, nil)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Persist bearer token for a server into Kamare settings
function KavitaBrowser:persistBearerToken(server_name, server_url, token)
    if not self.kamare_settings then
        logger.warn("KavitaBrowser:persistBearerToken: no settings")
        return
    end

    local servers = self.kamare_settings:readSetting("servers", {}) or {}
    local found = false

    if type(servers) == "table" then
        for i, s in ipairs(servers) do
            if type(s) == "table" and (s.url == server_url or s.name == server_name) then
                -- Update token and metadata
                servers[i].bearer = token
                servers[i].updated_at = os.time()
                found = true
                break
            end
        end
        if not found then
            -- Insert a new entry with the agreed nomenclature
            table.insert(servers, {
                name = server_name,
                url = server_url,
                bearer = token,
                updated_at = os.time(),
            })
        end
    else
        servers = {
            {
                name = server_name,
                url = server_url,
                bearer = token,
                updated_at = os.time(),
            }
        }
    end

    self.kamare_settings:saveSetting("servers", servers)
    self.servers = servers
end

-- Authenticate after selecting a server using config (no dialog)
function KavitaBrowser:authenticateAfterSelection(server_name, server_url)
    if not self.kamare_settings then
        logger.warn("KavitaBrowser:authenticateAfterSelection: no settings available")
        return
    end

    local servers = self.kamare_settings:readSetting("servers", {}) or {}

    -- Always (re)authenticate after selection to ensure fresh token

    -- Find matching server entry
    local entry
    for i, s in ipairs(servers) do
        if type(s) == "table" and (s.url == server_url or s.name == server_name) then
            entry = s
            break
        end
    end
    if not entry then
        logger.warn("KavitaBrowser:authenticateAfterSelection: server entry not found", server_name, server_url)
        return
    end

    -- Resolve API key and base server URL (no fallbacks)
    local apiKey = entry.api_key
    local base_url = entry.kavita_url

    if not apiKey or apiKey == "" or not base_url or base_url == "" then
        logger.warn("KavitaBrowser:authenticateAfterSelection: missing api_key or kavita_url")
        return
    end

    -- Authenticate and persist bearer token
    local token, code, __, err = KavitaClient:authenticate(base_url, apiKey)
    if not token then
        logger.warn("KavitaBrowser:authenticateAfterSelection: authentication failed", code, err)
        return
    end

    -- Keep client api_key for endpoints that require it as query param
    KavitaClient.api_key = apiKey

    self:persistBearerToken(server_name, server_url, token)
end


local function buildRootEntry(server)
    return {
        text       = server.name,
        url        = server.kavita_url,
        searchable = server.kavita_url and server.kavita_url:match("%%s") and true or false,
    }
end

-- Builds the root list of catalogs
function KavitaBrowser:genItemTableFromRoot()
    local item_table = {}
    if self.servers then
        for _, server in ipairs(self.servers) do
            table.insert(item_table, buildRootEntry(server))
        end
    end
    return item_table
end

-- Shows dialog to edit properties of the new/existing catalog
function KavitaBrowser:addEditServer(item, is_edit)
    if is_edit == nil then is_edit = item ~= nil end
    local fields = {
        {
            hint = _("Server name"),
        },
        {
            hint = _("Server URL"),
        },
        {
            hint = _("API key"),
        },
    }
    local title
    if is_edit then
        title = _("Edit Kavita server")
        fields[1].text = item.text
        fields[2].text = item.url
        fields[3].text = (self.servers and self.servers[item.idx] and self.servers[item.idx].api_key) or nil
    else
        title = _("Add Kavita server")
    end

    local button_text = is_edit and _("Save") or _("Add")
    local dialog
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = button_text,
                    callback = function()
                        local new_fields = dialog:getFields()
                        self:editServerFromInput(new_fields, item)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end


-- Saves catalog properties from input dialog
function KavitaBrowser:editServerFromInput(fields, item)
    local new_server = {
        name        = fields[1],
        kavita_url  = fields[2]:match("^%a+://") and fields[2] or "http://" .. fields[2],
        api_key     = fields[3] ~= "" and fields[3] or nil,
    }
    local new_item = buildRootEntry(new_server)
    local new_idx, itemnumber

    -- Initialize servers table if it doesn't exist
    if not self.servers then
        self.servers = {}
    end

    if item then
        new_idx = item.idx
        itemnumber = -1
    else
        new_idx = #self.servers + 1
        itemnumber = new_idx
    end
    self.servers[new_idx] = new_server
    self.item_table[new_idx] = new_item
    self:switchItemTable(nil, self.item_table, itemnumber)

    -- Save servers to settings (will be flushed by main plugin)
    if self.kamare_settings then
        self.kamare_settings:saveSetting("servers", self.servers)
    end
end

-- Deletes catalog from the root list
function KavitaBrowser:deleteCatalog(item)
    table.remove(self.servers, item.idx)
    table.remove(self.item_table, item.idx)
    self:switchItemTable(nil, self.item_table, -1)

    -- Save servers to settings (will be flushed by main plugin)
    if self.kamare_settings then
        self.kamare_settings:saveSetting("servers", self.servers)
    end
end

-- Handle errors from catalog fetching
function KavitaBrowser:handleCatalogError(context, item_url, error_msg)
    logger.info("Cannot get catalog info from", item_url, error_msg)

    local message
    if context == "dashboard" then
        message = _("Cannot load dashboard. Please check your connection.")
    elseif context == "search" then
        message = _("Search failed. Please try again.")
    elseif context == "series" then
        message = _("Cannot load series details. Please check your connection.")
    elseif context == "stream" then
        message = _("Cannot load content. Please check your connection.")
    else
        message = _("Cannot load data from server. Please check your connection.")
    end

    UIManager:show(InfoMessage:new{
        text = message,
    })
end

-- Launch the Kavita chapter viewer using Reader/image endpoint
function KavitaBrowser:launchKavitaChapterViewer(chapter, series_name, is_volume)
    if not chapter or not chapter.id then return end

    local pages = chapter.pages or (chapter.files and #chapter.files) or 0
    if pages <= 0 then
        local message = is_volume and _("This volume has no pages to display") or _("This chapter has no pages to display")
        UIManager:show(InfoMessage:new{ text = message })
        return
    end

    -- Make sure client has bearer/base_url/api_key (authenticateAfterSelection sets those)
    local page_table = KavitaClient:streamChapter(chapter.id)

    -- Keep lazy 1-based images list; client converts to 0-based for API
    local images_list_data = page_table

    -- Convert Kavita's pagesRead (count of pages read) to next 1-based page
    local start_page = 1
    if type(chapter.pagesRead) == "number" then
        local pr = math.max(0, math.floor(chapter.pagesRead))
        if pr >= pages then
            start_page = pages
        else
            start_page = pr + 1
        end
    end

    local function normalize_authors(a)
        if type(a) == "string" then return a end
        if type(a) == "table" then
            local names = {}
            for _, v in ipairs(a) do
                if type(v) == "string" then
                    table.insert(names, v)
                elseif type(v) == "table" and v.name then
                    table.insert(names, v.name)
                end
            end
            if #names > 0 then return table.concat(names, ", ") end
        end
    end

    local author =
        (self.current_series_names and normalize_authors(self.current_series_names.author))
        or self.catalog_author
        or normalize_authors(chapter.writers)

    local series_names = self.current_series_names or {}

    local content_type = "auto"

    if is_volume == true then
        content_type = "volume"
    elseif is_volume == false then
        content_type = "chapter"
    elseif is_volume == nil then
        -- Auto-detect based on chapter.range
        -- Kavita uses -100000 as sentinel value for volumes
        -- Positive numbers indicate chapter numbers
        if chapter.range then
            local range = tonumber(chapter.range)
            if range and range < 0 then
                content_type = "volume"
            elseif range and range >= 0 then
                content_type = "chapter"
            end
        end
    end

    local metadata = {
        -- Primary labels
        seriesName    = series_name or series_names.localizedName or series_names.name,
        author        = author,

        -- Alternate/localized/original names if known
        originalName  = series_names.originalName,
        localizedName = series_names.localizedName,

        -- IDs for progress/integration
        seriesId      = self.current_series_id,
        libraryId     = self.current_series_library_id,
        volumeId      = chapter.volumeId,
        chapterId     = chapter.id,

        -- Keep raw chapter for any further needs
        chapter       = chapter,

        -- Reader state
        startPage     = start_page,

        content_type  = content_type,
    }


    local preloaded_dimensions
    do
        local dims, code = KavitaClient:getFileDimensions(chapter.id)
        if type(code) == "number" and code >= 200 and code < 300 and type(dims) == "table" then
            -- Convert possible 0-based page indices to 1-based for the viewer
            local zero_based = false
            for _, d in ipairs(dims) do
                local pn = d.pageNumber or d.page or d.page_num
                if type(pn) == "number" and pn == 0 then
                    zero_based = true
                    break
                end
            end
            if zero_based then
                for _, d in ipairs(dims) do
                    if type(d.pageNumber) == "number" then d.pageNumber = d.pageNumber + 1 end
                    if type(d.page) == "number" then d.page = d.page + 1 end
                    if type(d.page_num) == "number" then d.page_num = d.page_num + 1 end
                end
            end
            preloaded_dimensions = dims
        else
            logger.warn("KavitaBrowser: getFileDimensions failed:", code)
        end
    end

    local preloaded_iswide = {}
    if type(preloaded_dimensions) == "table" then
        for _, d in ipairs(preloaded_dimensions) do
            local pn = d.pageNumber or d.page or d.page_num
            if type(pn) == "number" then
                preloaded_iswide[pn] = d.isWide and true or false
            end
        end
    end

    local viewer = KamareImageViewer:new{
        ui = self.ui,
        images_list_data = images_list_data,
        title = metadata.seriesName or _("Manga"),
        fullscreen = true,
        with_title_bar = false,
        images_list_nb = pages,
        preloaded_dimensions = preloaded_dimensions,
        preloaded_iswide = preloaded_iswide,
        metadata = metadata,
        kamare_settings = self.kamare_settings,
        on_close_callback = function(current_page, total_pages)
            local sid = self.current_series_id
            if not sid then return end
            local lid = self.current_series_library_id
            local sname = self.catalog_title
                or (self.current_series_names and (self.current_series_names.localizedName or self.current_series_names.name))
                or _("Series")
            UIManager:nextTick(function()
                self:showSeriesDetail(sname, sid, lid, { refresh_only = true })
            end)
        end,
        on_next_chapter_callback = function(next_chapter_id)
            -- Fetch the next chapter details and launch viewer
            UIManager:nextTick(function()
                local loading = InfoMessage:new{ text = _("Loading next chapter..."), timeout = 0 }
                UIManager:show(loading)
                UIManager:forceRePaint()

                -- Get series detail to find the chapter
                local sid = self.current_series_id
                if not sid then
                    UIManager:close(loading)
                    UIManager:show(InfoMessage:new{ text = _("Cannot load next chapter: missing series info") })
                    return
                end

                local detail, _ = KavitaClient:getSeriesDetail(sid)
                UIManager:close(loading)

                if not detail then
                    UIManager:show(InfoMessage:new{ text = _("Failed to load next chapter") })
                    return
                end

                -- Find the chapter with matching ID
                local next_chapter
                if detail.volumes then
                    for _, vol in ipairs(detail.volumes) do
                        if vol.chapters then
                            for _, ch in ipairs(vol.chapters) do
                                if ch.id == next_chapter_id then
                                    next_chapter = ch
                                    break
                                end
                            end
                        end
                        if next_chapter then break end
                    end
                end
                if not next_chapter and detail.chapters then
                    for _, ch in ipairs(detail.chapters) do
                        if ch.id == next_chapter_id then
                            next_chapter = ch
                            break
                        end
                    end
                end
                if not next_chapter and detail.specials then
                    for _, ch in ipairs(detail.specials) do
                        if ch.id == next_chapter_id then
                            next_chapter = ch
                            break
                        end
                    end
                end

                if not next_chapter then
                    UIManager:show(InfoMessage:new{ text = _("Next chapter not found") })
                    return
                end

                -- Launch the viewer for the next chapter
                local sname = self.catalog_title
                    or (self.current_series_names and (self.current_series_names.localizedName or self.current_series_names.name))
                    or _("Series")
                self:launchKavitaChapterViewer(next_chapter, sname)
            end)
        end,
    }
    UIManager:show(viewer)
    return viewer
end

-- Menu action on item tap (Stream a book / Show subcatalog / Search in catalog)
function KavitaBrowser:onMenuSelect(item)
    -- Only Kavita items are supported
    if item.kavita_chapter and item.chapter and item.chapter.id then
        self:launchKavitaChapterViewer(item.chapter, self.catalog_title or self.current_server_name, false)
        return true
    end

    if item.kavita_volume and item.volume and item.volume.id then
        local vol = item.volume
        local ch = (type(vol.chapters) == "table") and vol.chapters[1] or nil
        if ch and ch.id then
            self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true)
        else
            UIManager:show(InfoMessage:new{ text = _("This volume has no chapters available.") })
        end
        return true
    end

    if item.kavita_recently_added and item.recent and item.recent.seriesId then
        self:showSeriesDetail(item.text, item.recent.seriesId, nil)
        return true
    end

    if item.kavita_series and item.series then
        local sid = item.series.id or item.series.seriesId
        local lid = item.series.libraryId or (item.series.library and item.series.library.id)
        if sid then
            -- Remember series naming metadata for the reader
            local s = item.series or {}
            self.current_series_names = {
                name = item.text,
                originalName = s.originalName or s.seriesName or s.name,
                localizedName = s.localizedName,
                -- Raw author data if present; will be normalized later
                author = s.author or s.authors or s.writers,
            }
            self:showSeriesDetail(item.text, sid, lid)
            return true
        end
    end

    if item.kavita_dashboard then
        local stream_name = item.kavita_stream_name or (item.dashboard and item.dashboard.name)
        if not stream_name or stream_name == "" then
            UIManager:show(InfoMessage:new{ text = _("Invalid dashboard item") })
            return true
        end
        self:showKavitaStream(stream_name)
        return true
    end

    if #self.paths == 0 then -- root list
        self.current_server_name    = item.text
        self:authenticateAfterSelection(item.text, item.url)
        self:showDashboardAfterSelection(item.text)
        return true
    end

    return true
end

-- Menu action on item long-press (dialog Edit / Delete catalog)
function KavitaBrowser:onMenuHold(item)
    -- Handle series long-press for continue reading
    if item.kavita_series and item.series then
        local series = item.series
        local sid = series.id or series.seriesId
        local lid = series.libraryId or (series.library and series.library.id)

        if not sid then
            UIManager:show(InfoMessage:new{ text = _("Series ID not available") })
            return true
        end

        local dialog
        local buttons = {
            {
                {
                    text = _("Continue Reading") .. " \u{25B6}",
                    callback = function()
                        UIManager:close(dialog)

                        local loading = InfoMessage:new{ text = _("Loading..."), timeout = 0 }
                        UIManager:show(loading)
                        UIManager:forceRePaint()

                        local chapter, _ = KavitaClient:getContinuePoint(sid)

                        UIManager:close(loading)

                        if not chapter then
                            UIManager:show(InfoMessage:new{ text = _("Failed to get continue point") })
                            return
                        end

                        self.current_series_id = sid
                        self.current_series_library_id = lid
                        self.current_series_names = {
                            name = item.text,
                            originalName = series.originalName or series.seriesName or series.name,
                            localizedName = series.localizedName,
                            author = series.author or series.authors or series.writers,
                        }

                        self:launchKavitaChapterViewer(chapter, item.text)
                    end,
                },
                {
                    text = _("View Series"),
                    callback = function()
                        UIManager:close(dialog)
                        self.current_series_names = {
                            name = item.text,
                            originalName = series.originalName or series.seriesName or series.name,
                            localizedName = series.localizedName,
                            author = series.author or series.authors or series.writers,
                        }
                        self:showSeriesDetail(item.text, sid, lid)
                    end,
                },
            },
        }

        dialog = ButtonDialog:new{
            title = item.text,
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    -- Handle chapter/volume long-press for reading options
    if item.kavita_chapter and item.chapter and item.chapter.id then
        local chapter = item.chapter
        local pages = chapter.pages or (chapter.files and #chapter.files) or 0
        if pages <= 0 then
            UIManager:show(InfoMessage:new{ text = _("This chapter has no pages to display") })
            return true
        end

        local dialog
        local buttons = {
            {
                {
                    text = "\u{23EE} " .. _("From start"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Override start page to 1
                        local original_pages_read = chapter.pagesRead
                        chapter.pagesRead = 0
                        self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name, false)
                        chapter.pagesRead = original_pages_read
                    end,
                },
                {
                    text = _("Continue") .. " \u{25B6}",
                    callback = function()
                        UIManager:close(dialog)
                        -- Use normal behavior (resume from pagesRead)
                        self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name, false)
                    end,
                },
            },
        }

        -- Add "Jump to" option if there are pages to jump to
        if pages > 1 then
            table.insert(buttons, {
                {
                    text = _("Jump to page") .. " \u{23E9}",
                    callback = function()
                        UIManager:close(dialog)
                        local jump_dialog
                        jump_dialog = InputDialog:new{
                            title = _("Jump to page"),
                            input_hint = T(_("1 - %1"), pages),
                            input_type = "number",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(jump_dialog)
                                        end,
                                    },
                                    {
                                        text = _("Jump"),
                                        is_enter_default = true,
                                        callback = function()
                                            local page_str = jump_dialog:getInputText()
                                            local page_num = tonumber(page_str)
                                            UIManager:close(jump_dialog)
                                            if not page_num or page_num < 1 or page_num > pages then
                                                UIManager:show(InfoMessage:new{ text = T(_("Invalid page number. Please enter 1 - %1"), pages) })
                                                return
                                            end
                                            -- Override start page
                                            local original_pages_read = chapter.pagesRead
                                            chapter.pagesRead = page_num - 1
                                            self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name, false)
                                            chapter.pagesRead = original_pages_read
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(jump_dialog)
                        jump_dialog:onShowKeyboard()
                    end,
                },
            })
        end

        -- Add "Mark as read" option
        table.insert(buttons, {})  -- separator
        table.insert(buttons, {
            {
                text = "\u{2713} " .. _("Mark as read"),
                callback = function()
                    UIManager:close(dialog)
                    -- Mark as read by reporting the last page as progress
                    local progress = {
                        volumeId  = chapter.volumeId,
                        chapterId = chapter.id,
                        pageNum   = pages + 1,  -- i lost the thread on page numbers so lets overshoot
                        seriesId  = self.current_series_id,
                        libraryId = self.current_series_library_id,
                    }
                    local code = KavitaClient:postReaderProgress(progress)
                    if code == 200 or code == 204 then
                        UIManager:show(InfoMessage:new{ text = _("Marked as read") })
                        -- Refresh the series view to update progress indicators
                        local sid = self.current_series_id
                        if sid then
                            local lid = self.current_series_library_id
                            local sname = self.catalog_title
                                or (self.current_series_names and (self.current_series_names.localizedName or self.current_series_names.name))
                                or _("Series")
                            UIManager:nextTick(function()
                                self:showSeriesDetail(sname, sid, lid, { refresh_only = true })
                            end)
                        end
                    else
                        UIManager:show(InfoMessage:new{ text = _("Failed to mark as read") })
                    end
                end,
            },
        })

        dialog = ButtonDialog:new{
            title = item.text,
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    -- Handle volume long-press for reading options
    if item.kavita_volume and item.volume and item.volume.id then
        local vol = item.volume
        local ch = (type(vol.chapters) == "table") and vol.chapters[1] or nil
        if not ch or not ch.id then
            UIManager:show(InfoMessage:new{ text = _("This volume has no chapters available.") })
            return true
        end

        local pages = ch.pages or (ch.files and #ch.files) or 0
        if pages <= 0 then
            UIManager:show(InfoMessage:new{ text = _("This volume has no pages to display") })
            return true
        end

        local dialog
        local buttons = {
            {
                {
                    text = "\u{23EE} " .. _("From start"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Override start page to 1
                        local original_pages_read = ch.pagesRead
                        ch.pagesRead = 0
                        self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true)
                        ch.pagesRead = original_pages_read
                    end,
                },
                {
                    text = _("Continue") .. " \u{25B6}",
                    callback = function()
                        UIManager:close(dialog)
                        -- Use normal behavior (resume from pagesRead)
                        self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true)
                    end,
                },
            },
        }

        -- Add "Jump to" option if there are pages to jump to
        if pages > 1 then
            table.insert(buttons, {
                {
                    text = _("Jump to page") .. " \u{23E9}",
                    callback = function()
                        UIManager:close(dialog)
                        local jump_dialog
                        jump_dialog = InputDialog:new{
                            title = _("Jump to page"),
                            input_hint = T(_("1 - %1"), pages),
                            input_type = "number",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(jump_dialog)
                                        end,
                                    },
                                    {
                                        text = _("Jump"),
                                        is_enter_default = true,
                                        callback = function()
                                            local page_str = jump_dialog:getInputText()
                                            local page_num = tonumber(page_str)
                                            UIManager:close(jump_dialog)
                                            if not page_num or page_num < 1 or page_num > pages then
                                                UIManager:show(InfoMessage:new{ text = T(_("Invalid page number. Please enter 1 - %1"), pages) })
                                                return
                                            end
                                            -- Override start page
                                            local original_pages_read = ch.pagesRead
                                            ch.pagesRead = page_num - 1
                                            self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true)
                                            ch.pagesRead = original_pages_read
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(jump_dialog)
                        jump_dialog:onShowKeyboard()
                    end,
                },
            })
        end

        -- Add "Mark as read" option
        table.insert(buttons, {})  -- separator
        table.insert(buttons, {
            {
                text = "\u{2713} " .. _("Mark as read"),
                callback = function()
                    UIManager:close(dialog)
                    -- Mark as read by reporting the last page as progress
                    local progress = {
                        volumeId  = ch.volumeId,
                        chapterId = ch.id,
                        pageNum   = pages,  -- i lost the thread on page numbers so lets overshoot
                        seriesId  = self.current_series_id,
                        libraryId = self.current_series_library_id,
                    }
                    local code = KavitaClient:postReaderProgress(progress)
                    if code == 200 or code == 204 then
                        UIManager:show(InfoMessage:new{ text = _("Marked as read") })
                        -- Refresh the series view to update progress indicators
                        local sid = self.current_series_id
                        if sid then
                            local lid = self.current_series_library_id
                            local sname = self.catalog_title
                                or (self.current_series_names and (self.current_series_names.localizedName or self.current_series_names.name))
                                or _("Series")
                            UIManager:nextTick(function()
                                self:showSeriesDetail(sname, sid, lid, { refresh_only = true })
                            end)
                        end
                    else
                        UIManager:show(InfoMessage:new{ text = _("Failed to mark as read") })
                    end
                    UIManager:close(dialog)
                end,
            },
        })

        dialog = ButtonDialog:new{
            title = item.text,
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    -- Handle server (root list) long-press for Edit/Delete
    if #self.paths > 0 then return true end -- not root list
    local dialog
    dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete Kavita server?"),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                UIManager:close(dialog)
                                self:deleteCatalog(item)
                            end,
                        })
                    end,
                },
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        self:addEditServer(item, true)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

-- Menu action on previous-page chevron tap
function KavitaBrowser:onPrevPage()
    return Menu.onPrevPage(self)
end

-- Menu action on return-arrow tap (go to one-level upper catalog)
function KavitaBrowser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if path then
        self.catalog_title = path.title
        self.catalog_author = path.author
        if path.kavita_stream_root then
            -- return to the last stream list
            if path.kavita_stream_root then
                self:showKavitaStream(path.kavita_stream_root)
            else
                self:init()
            end
        elseif path.kavita_dashboard_root then
            -- return to dashboard for current server
            self:showDashboardAfterSelection(self.current_server_name or self.catalog_title)
        else
            self:init()
        end
    else
        -- return to root path, we simply reinit KavitaBrowser
        self:init()
    end
    return true
end


-- Menu action on return-arrow long-press (return to root path)
function KavitaBrowser:onHoldReturn()
    self:init()
    return true
end

-- Menu action on next-page chevron tap
function KavitaBrowser:onNextPage()
    return Menu.onNextPage(self)
end

return KavitaBrowser
