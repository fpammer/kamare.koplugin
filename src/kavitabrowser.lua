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
}

function KavitaBrowser:init()
    -- Initialize paths table here to avoid nil errors
    self.paths = self.paths or {}

    -- Track if this is the initial startup of this browser instance (not navigation back)
    local is_initial_browser_startup = not self.has_initialized_before
    self.has_initialized_before = true

    -- Check if we have exactly one server and it's the initial browser startup
    if is_initial_browser_startup and self.servers and #self.servers == 1 then
        local single_server = self.servers[1]
        -- First initialize the Menu normally
        self.item_table = {}
        self.catalog_title = nil
        self.title_bar_left_icon = "appbar.menu"
        self.onLeftButtonTap = function()
            self:showTitleMenu()
        end

        Menu.init(self) -- Initialize Menu first

        -- Then load the server's content
        logger.dbg("KavitaBrowser:init: auto-selecting single server", single_server.name, single_server.url)
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
local function buildKavitaDashboardItems(dashboard)
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

            table.insert(items, {
                text = name,
                kavita_dashboard = true,
                kavita_stream_name = api_name,
                dashboard = d, -- keep full dto for future navigation
            })
        end
    end

    -- Manually add "Want to Read" after the dashboard items
    table.insert(items, {
        text = "Want to Read",
        kavita_dashboard = true,
        kavita_stream_name = "want-to-read",
        dashboard = { name = "want-to-read" },
    })

    return items
end

-- Fetch dashboard and display it as the server root list
function KavitaBrowser:showDashboardAfterSelection(server_name)
    local loading = InfoMessage:new{ text = _("Loading..."), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local data, code, headers, status, body = KavitaClient:getDashboard()

    UIManager:close(loading)

    if not data then
        self:handleCatalogError("/api/Stream/dashboard", status or code)
        return
    end

    local items = buildKavitaDashboardItems(data)
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

    local result, code, headers, status, body = KavitaClient:getSearch(query, false)

    UIManager:close(loading)

    if not result then
        self:handleCatalogError("/api/Search/search", status or code)
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
    self.search_url = nil

    if not items or #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No results") })
    end
    self:switchItemTable(self.catalog_title, items, nil, nil, nil)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Build menu entries from a list of SeriesDto
function KavitaBrowser:buildKavitaSeriesItems(series_list)
    local items = {}
    if type(series_list) == "table" then
        for _, s in ipairs(series_list) do
            local name = s.localizedName or s.name or s.originalName or s.seriesName or s.title or _("Unnamed series")
            local subtitle = s.libraryName or (s.library and s.library.name)
            table.insert(items, {
                text = name,
                author = subtitle,
                kavita_series = true,
                series = s, -- keep full dto for next steps
            })
        end
    end
    return items
end

-- Build menu entries from a list of RecentlyAddedItemDto (used by Recently Updated)
local function buildKavitaRecentlyAddedItems(list)
    local items = {}
    if type(list) == "table" then
        for _, v in ipairs(list) do
            local name = v.seriesName or v.title or _("Recently updated item")
            local subtitle_parts = {}
            if v.title and v.title ~= "" then table.insert(subtitle_parts, v.title) end
            if v.created and v.created ~= "" then table.insert(subtitle_parts, v.created) end
            local subtitle = #subtitle_parts > 0 and table.concat(subtitle_parts, " • ") or nil
            table.insert(items, {
                text = name,
                author = subtitle,
                kavita_recently_added = true,
                recent = v, -- keep full dto (seriesId, title, created, etc.)
            })
        end
    end
    return items
end

-- Build menu entries for VolumeDto[]
local function buildKavitaVolumeItems(volumes)
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
            table.insert(items, {
                text = name,
                author = subtitle,
                mandatory = mandatory,
                kavita_volume = true,
                volume = v,
            })
        end
    end
    return items
end

-- Build menu entries for ChapterDto[]
local function buildKavitaChapterItems(chapters, kind)
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

            table.insert(items, {
                text = name,
                author = subtitle,
                mandatory = mandatory,
                kavita_chapter = true,
                chapter = c,
                is_special = (kind == "special") or nil,
            })
        end
    end
    return items
end

-- Fetch SeriesDetail and display Volumes, then Chapters, then Specials
function KavitaBrowser:showSeriesDetail(series_name, series_id, library_id, opts)
    local loading = InfoMessage:new{ text = _("Loading..."), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local detail, code, headers, status, body = KavitaClient:getSeriesDetail(series_id)

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
        self:handleCatalogError("/api/Series/series-detail?seriesId=" .. tostring(series_id), status or code)
        return
    end

    local items = {}
    for _, it in ipairs(buildKavitaVolumeItems(detail.volumes or {})) do table.insert(items, it) end
    for _, it in ipairs(buildKavitaChapterItems(detail.chapters or {}, "chapter")) do table.insert(items, it) end
    for _, it in ipairs(buildKavitaChapterItems(detail.specials or {}, "special")) do table.insert(items, it) end

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
        local data, code, headers, status, body = KavitaClient:getStreamSeries(stream_name, { PageNumber = page_num, PageSize = page_size })

        if not data then
            UIManager:close(loading)
            self:handleCatalogError("/api/Stream/" .. tostring(stream_name), status or code)
            return
        end

        logger.dbg("KavitaBrowser:showKavitaStream: page", page_num, "type(data) =", type(data), "array_len =", (type(data) == "table" and #data or 0))

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
    logger.dbg("KavitaBrowser:showKavitaStream: total items =", (type(data) == "table" and #data or 0))

    -- Special handling: Recently Updated returns RecentlyAddedItemDto[]
    if stream_name == "recently-updated" or stream_name == "recently-updated-series" then
        local items = buildKavitaRecentlyAddedItems(data or {})

        self.catalog_title = _("Recently Updated")
        self.search_url = nil

        -- Remember current stream for back navigation from series detail
        self.current_stream_name = stream_name

        -- Push a stream sentinel so back returns to dashboard
        self.paths = self.paths or {}
        local top = self.paths[#self.paths]
        if not (top and top.kavita_stream_root == stream_name) then
            table.insert(self.paths, { kavita_stream_root = stream_name, title = self.catalog_title })
        end

        if not items or #items == 0 then
            UIManager:show(InfoMessage:new{ text = _("No items found") })
        end
        self:switchItemTable(self.catalog_title, items, nil, nil, nil)
        self:setTitleBarLeftIcon("appbar.menu")
        self.onLeftButtonTap = function()
            self:showTitleMenu()
        end
        return
    end

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
    logger.dbg("KavitaBrowser:showKavitaStream: normalized series_list len =", (type(series_list) == "table" and #series_list or 0))

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
    if not (self._manager and self._manager.kamare_settings) then
        logger.warn("KavitaBrowser:persistBearerToken: no manager/settings")
        return
    end
    logger.dbg("KavitaBrowser:persistBearerToken: begin", server_name, server_url, "token_len", (type(token) == "string" and #token or 0))
    local settings = self._manager.kamare_settings
    local servers = settings:readSetting("servers", {}) or {}
    local updated = false
    logger.dbg("KavitaBrowser:persistBearerToken: servers_len", #servers)

    if type(servers) == "table" then
        for i, s in ipairs(servers) do
            if type(s) == "table" and (s.url == server_url or s.name == server_name) then
                logger.dbg("KavitaBrowser:persistBearerToken: matched index", i, "existing_bearer_len", (type(s.bearer) == "string" and #s.bearer or 0))
                -- Update token and metadata
                servers[i].bearer = token
                servers[i].updated_at = os.time()
                updated = true
                break
            end
        end
        if not updated then
            -- Insert a new entry with the agreed nomenclature
            table.insert(servers, {
                name = server_name,
                url = server_url,
                bearer = token,
                updated_at = os.time(),
            })
            logger.dbg("KavitaBrowser:persistBearerToken: inserted new entry at index", #servers)
            updated = true
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
        logger.dbg("KavitaBrowser:persistBearerToken: rebuilt servers table with single entry")
    end

    settings:saveSetting("servers", servers)
    self._manager.servers = servers
    self.servers = servers
    self._manager.updated = true
    logger.dbg("KavitaBrowser:persistBearerToken: saved servers, will flush =", updated)

    if updated then
        settings:flush()
        logger.dbg("KavitaBrowser:persistBearerToken: settings flushed")
    end
end

-- Authenticate after selecting a server using config (no dialog)
function KavitaBrowser:authenticateAfterSelection(server_name, server_url)
    logger.dbg("KavitaBrowser:authenticateAfterSelection: start", server_name, server_url)
    local settings = self._manager and self._manager.kamare_settings
    if not settings then
        logger.warn("KavitaBrowser:authenticateAfterSelection: no settings available")
        return
    end

    local servers = settings:readSetting("servers", {}) or {}
    logger.dbg("KavitaBrowser:authenticateAfterSelection: servers_len", #servers)

    -- Always (re)authenticate after selection to ensure fresh token

    -- Find matching server entry
    local entry
    for i, s in ipairs(servers) do
        if type(s) == "table" and (s.url == server_url or s.name == server_name) then
            entry = s
            logger.dbg("KavitaBrowser:authenticateAfterSelection: matched server at index", i)
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
        logger.warn("KavitaBrowser:authenticateAfterSelection: missing api_key or kavita_url", "api_len", (apiKey and #apiKey or 0), "base_url", tostring(base_url))
        return
    end

    logger.dbg("KavitaBrowser:authenticateAfterSelection: calling KavitaClient.authenticate", base_url, "api_len", (apiKey and #apiKey or 0))
    -- Authenticate and persist bearer token
    local token, code, _, err = KavitaClient:authenticate(base_url, apiKey)
    if not token then
        logger.warn("KavitaBrowser:authenticateAfterSelection: authentication failed", code, err)
        return
    end
    logger.dbg("KavitaBrowser:authenticateAfterSelection: got token, len", #token)

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
    self._manager.updated = true
end

-- Deletes catalog from the root list
function KavitaBrowser:deleteCatalog(item)
    table.remove(self.servers, item.idx)
    table.remove(self.item_table, item.idx)
    self:switchItemTable(nil, self.item_table, -1)
    self._manager.updated = true
end

-- Handle errors from catalog fetching
function KavitaBrowser:handleCatalogError(item_url, error_msg)
    logger.info("Cannot get catalog info from", item_url, error_msg)
    UIManager:show(InfoMessage:new{
        text = T(_("Cannot get catalog info from %1"), (item_url and BD.url(item_url) or "nil")),
    })
end

-- Launch the Kavita chapter viewer using Reader/image endpoint
function KavitaBrowser:launchKavitaChapterViewer(chapter, series_name)
    if not chapter or not chapter.id then return end

    local pages = chapter.pages or (chapter.files and #chapter.files) or 0
    if pages <= 0 then
        UIManager:show(InfoMessage:new{ text = _("No pages to display") })
        return
    end

    -- Make sure client has bearer/base_url/api_key (authenticateAfterSelection sets those)
    local ctx = {
        series_id  = self.current_series_id,
        library_id = self.current_series_library_id,
        volume_id  = chapter.volumeId,
    }
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

    local KamareImageViewer = require("kamareimageviewer")
    local viewer = KamareImageViewer:new{
        images_list_data = images_list_data,
        title = metadata.seriesName or _("Manga"),
        fullscreen = true,
        with_title_bar = false,
        images_list_nb = pages,
        preloaded_dimensions = preloaded_dimensions,
        preloaded_iswide = preloaded_iswide,
        metadata = metadata,
        on_close_callback = function(current_page, total_pages)
            logger.dbg("Reader closed - ended at page", current_page, "of", total_pages)
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
    }
    UIManager:show(viewer)
    return viewer
end

-- Menu action on item tap (Stream a book / Show subcatalog / Search in catalog)
function KavitaBrowser:onMenuSelect(item)
    -- Only Kavita items are supported
    if item.kavita_chapter and item.chapter and item.chapter.id then
        self:launchKavitaChapterViewer(item.chapter, self.catalog_title or self.current_server_name)
        return true
    end
    if item.kavita_volume and item.volume and item.volume.id then
        local vol = item.volume
        local ch = (type(vol.chapters) == "table") and vol.chapters[1] or nil
        if ch and ch.id then
            self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name)
        else
            UIManager:show(InfoMessage:new{ text = _("No chapters in this volume") })
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
        logger.dbg("KavitaBrowser:onMenuSelect: root selection", item.text, item.url)
        self:authenticateAfterSelection(item.text, item.url)
        self:showDashboardAfterSelection(item.text)
        return true
    end
    return true
end

-- Menu action on item long-press (dialog Edit / Delete catalog)
function KavitaBrowser:onMenuHold(item)
    -- Handle chapter/volume long-press for reading options
    if item.kavita_chapter and item.chapter and item.chapter.id then
        local chapter = item.chapter
        local pages = chapter.pages or (chapter.files and #chapter.files) or 0
        if pages <= 0 then
            UIManager:show(InfoMessage:new{ text = _("No pages to display") })
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
                        self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name)
                        chapter.pagesRead = original_pages_read
                    end,
                },
                {
                    text = _("Continue") .. " \u{25B6}",
                    callback = function()
                        UIManager:close(dialog)
                        -- Use normal behavior (resume from pagesRead)
                        self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name)
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
                                            self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name)
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
                    local code, headers, status, body = KavitaClient:postReaderProgress(progress)
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
            UIManager:show(InfoMessage:new{ text = _("No chapters in this volume") })
            return true
        end

        local pages = ch.pages or (ch.files and #ch.files) or 0
        if pages <= 0 then
            UIManager:show(InfoMessage:new{ text = _("No pages to display") })
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
                        self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name)
                        ch.pagesRead = original_pages_read
                    end,
                },
                {
                    text = _("Continue") .. " \u{25B6}",
                    callback = function()
                        UIManager:close(dialog)
                        -- Use normal behavior (resume from pagesRead)
                        self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name)
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
                                            self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name)
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
                    -- Mark as read by reporting the last page as progress
                    local progress = {
                        volumeId  = chapter.volumeId,
                        chapterId = chapter.id,
                        pageNum   = pages,  -- i lost the thread on page numbers so lets overshoot
                        seriesId  = self.current_series_id,
                        libraryId = self.current_series_library_id,
                    }
                    local code, headers, status, body = KavitaClient:postReaderProgress(progress)
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
