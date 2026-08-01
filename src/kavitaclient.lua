local Device = require("device")
local Version = require("version")
local Cache = require("cache")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local rapidjson = require("rapidjson")
local md5 = require("ffi/sha2").md5
local AsyncFetch = require("kamareasyncfetch")
local time = require("ui/time")

local ApiCache = Cache:new{
    slots = 20,
}

local KavitaClient = {
    device_id = nil,
    client_info_header = nil,
    auth_method = "bearer", -- bearer token (legacy) | apiKey in header x-api-key
}

-- Helper function to compare semantic version strings
-- Returns: -1 if v1 < v2, 1 if v1 > v2, 0 if equal
function KavitaClient:compareVersions(v1, v2)
    -- Split version strings into components
    local function splitVersion(version)
        local components = {}
        for component in version:gmatch("(%d+)") do
            table.insert(components, tonumber(component))
        end
        return components
    end

    local comp1 = splitVersion(v1)
    local comp2 = splitVersion(v2)

    -- Pad the shorter version with zeros for comparison
    local max_length = math.max(#comp1, #comp2)
    for i = #comp1 + 1, max_length do
        table.insert(comp1, 0)
    end
    for i = #comp2 + 1, max_length do
        table.insert(comp2, 0)
    end

    -- Compare component by component
    for i = 1, max_length do
        if comp1[i] < comp2[i] then
            return -1
        elseif comp1[i] > comp2[i] then
            return 1
        end
    end

    return 0
end

function KavitaClient:setDeviceId(device_id)
    self.device_id = device_id

    return self.device_id
end

function KavitaClient:_generateClientInfoHeader()
    if self.client_info_header then
        return self.client_info_header
    end

    local device_info = {
        appVersion = "unknown",
        deviceType = "Tablet",
        platform = "Unknown",
        screenWidth = "unknown",
        screenHeight = "unknown",
        orientation = "unknown",
        browser = "kamare",
        browserVersion = "unknown"
    }

    local version = Version:getShortVersion() or "unknown"

    if version and version ~= "" then
        device_info.appVersion = version
        device_info.browserVersion = version
    end

    if Device then
        if Device.screen and Device.screen.getWidth and Device.screen.getHeight then
            device_info.screenWidth = tostring(Device.screen:getWidth() or "unknown")
            device_info.screenHeight = tostring(Device.screen:getHeight() or "unknown")
        end

        if Device.screen and Device.screen.getRotationMode then
            local rotation_mode = Device.screen:getRotationMode()
            if rotation_mode then
                -- 0 or 2 = portrait, 1 or 3 = landscape
                device_info.orientation = (rotation_mode == 0 or rotation_mode == 2) and "portrait" or "landscape"
            end
        end

        -- Fallback: use screen dimensions if orientation still unknown
        if device_info.orientation == "unknown" and
           device_info.screenWidth ~= "unknown" and device_info.screenHeight ~= "unknown" then
            local width = tonumber(device_info.screenWidth) or 0
            local height = tonumber(device_info.screenHeight) or 0
            device_info.orientation = width > height and "landscape" or "portrait"
        end
    end

    -- Format: "web-app/version (Browser/version; Platform; DeviceType; screenWidth x screenHeight; orientation)"
    local header = string.format("web-app/%s (%s/%s; %s; %s; %sx%s; %s)",
        device_info.appVersion,
        device_info.browser,
        device_info.browserVersion,
        device_info.platform,
        device_info.deviceType,
        device_info.screenWidth,
        device_info.screenHeight,
        device_info.orientation
    )

    self.client_info_header = header

    return header
end

function KavitaClient:authenticate(server_url, apiKey)
    local base_endpoint = (server_url:gsub("/+$", "")) .. "/api/Plugin/authenticate"
    local auth_url = base_endpoint .. "?apiKey=" .. url.escape(apiKey) .. "&pluginName=" .. url.escape("KaMaRe.koplugin")
    local sink = {}

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request{
            url     = auth_url,
            method  = "POST",
            headers = {
                ["Accept"] = "application/json",
                ["X-Device-Id"] = self.device_id,
            },
            sink    = ltn12.sink.table(sink),
        })
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("KavitaClient:authenticate: request failed with LuaSocket error:", code)
        return nil, -1, nil, code
    end

    if code ~= 200 and code ~= 201 then
        logger.warn("KavitaClient:authenticate: non-OK status:", code, status)
        return nil, code, headers, status
    end

    local body = table.concat(sink)
    local okj, decoded = pcall(rapidjson.decode, body)
    if not okj or type(decoded) ~= "table" then
        logger.warn("KavitaClient:authenticate: JSON decode failed")
        return nil, code, headers, "Invalid JSON auth response"
    end

    local token = decoded.token
    if type(token) ~= "string" or token == "" then
        logger.warn("KavitaClient:authenticate: token missing in JSON response")
        return nil, code, headers, "No token in JSON response"
    end

    -- Persist on the client for subsequent API calls
    self.bearer   = token
    self.base_url = (server_url:gsub("/+$", ""))
    self.api_key  = apiKey

    return token, code, headers, status
end

-- Internal: build a URL-encoded query string from a table
function KavitaClient:_buildQueryString(params)
    if type(params) ~= "table" or not next(params) then return "" end
    local parts = {}
    for k, v in pairs(params) do
        local key = url.escape(tostring(k))
        if type(v) == "table" then
            for _, vv in ipairs(v) do
                table.insert(parts, key .. "=" .. url.escape(tostring(vv)))
            end
        else
            table.insert(parts, key .. "=" .. url.escape(tostring(v)))
        end
    end
    return (#parts > 0) and ("?" .. table.concat(parts, "&")) or ""
end

function KavitaClient:_makeCacheKey(method, path, query, body)
    local base = tostring(self.base_url or "")
    local method_str = tostring(method or "GET")
    local q = self:_buildQueryString(query) or ""
    local b = (type(body) == "table") and rapidjson.encode(body) or (body ~= nil and tostring(body) or "")
    local raw = table.concat({ base, method_str, q, b }, "|")
    local hash = md5(raw)
    return string.format("kavita|json|%s|%s", tostring(path or ""), hash)
end

function KavitaClient:_cacheGet(key, ttl)
    local ok, cached = pcall(ApiCache.check, ApiCache, key)
    if ok and cached and cached.timestamp then
        local age = os.time() - cached.timestamp
        if age >= 0 and age < (ttl or 300) then
            return cached.data
        end
    end
end

function KavitaClient:_cachePut(key, data)
    local payload = { data = data, timestamp = os.time() }
    local ok, err = pcall(ApiCache.insert, ApiCache, key, payload)
    if not ok then
        logger.warn("KavitaClient:_cachePut failed:", err)
    end
end

-- Cached JSON helper: returns decoded JSON with TTL
function KavitaClient:apiJSONCached(path, opts, ttl, ns)
    opts = opts or {}
    local key = self:_makeCacheKey(opts.method or "GET", path, opts.query, opts.body)
    local hit = self:_cacheGet(key, ttl or 300)
    if hit ~= nil then
        return hit, 200, nil, "cached", nil
    end
    local data, code, headers, status, body = self:apiJSON(path, opts)
    if data ~= nil then
        self:_cachePut(key, data)
    end
    return data, code, headers, status, body
end

-- Generic API request entry point. Wraps _apiRequestImpl with timing and
-- error logging; re-raises (level 2, blaming the caller) on failure.
-- Returns: code, headers, status, body_string
function KavitaClient:apiRequest(path, opts)
    local t0 = time.now()
    local ok, code, headers, status, body = pcall(KavitaClient._apiRequestImpl, self, path, opts)
    local elapsed_ms = time.to_ms(time.now() - t0)
    local method = (opts and opts.method) or "GET"
    if not ok then
        -- on error, `code` holds the error message
        logger.dbg(string.format("[kamare:fetch] FAIL %s %s %dms: %s", method, path, elapsed_ms, tostring(code)))
        error(code, 2)
    end
    local body_len = (type(body) == "string") and #body or 0
    logger.dbg(string.format("[kamare:fetch] %s %s code=%s bytes=%d %dms",
        method, path, tostring(code), body_len, elapsed_ms))
    return code, headers, status, body
end

-- Build the common request headers (Accept, Accept-Encoding, device, client)
-- and add the active auth credential (x-api-key or Authorization: Bearer).
-- `accept` sets the Accept header value. Returns (headers) on success, or
-- (nil, err) when no authentication is configured.
function KavitaClient:_buildAuthHeaders(accept)
    local headers = {
        ["Accept"] = accept,
        ["Accept-Encoding"] = "identity",
        ["X-Device-Id"] = self.device_id,
        ["X-Kavita-Client"] = self:_generateClientInfoHeader(),
    }
    if self.auth_method == "apiKey" and self.api_key and self.api_key ~= "" then
        headers["x-api-key"] = self.api_key
    elseif self.bearer and self.bearer ~= "" then
        headers["Authorization"] = "Bearer " .. self.bearer
    else
        return nil, "No authentication available"
    end
    return headers
end

-- Generic API request with Authorization: Bearer / x-api-key.
function KavitaClient:_apiRequestImpl(path, opts)
    opts = opts or {}
    local method = opts.method or "GET"
    local query = opts.query
    local body = opts.body
    local extra_headers = opts.headers or {}
    local accept_format = opts.accept_format or "json"  -- "json" or "text"

    if not self.base_url then
        logger.warn("KavitaClient:apiRequest: missing base_url")
        return -1, nil, "Missing base_url", nil
    end

    -- Check authentication based on method
    if self.auth_method == "apiKey" and (not self.api_key or self.api_key == "") then
        logger.warn("KavitaClient:apiRequest: missing api_key for API key authentication")
        return -1, nil, "Missing api_key", nil
    elseif self.auth_method == "bearer" and (not self.bearer or self.bearer == "") then
        logger.warn("KavitaClient:apiRequest: missing bearer for bearer authentication")
        return -1, nil, "Missing bearer", nil
    end

    local base = self.base_url:gsub("/+$", "")
    local p = tostring(path or "")
    if p == "" then
        logger.warn("KavitaClient:apiRequest: empty path")
        return -1, nil, "Empty path", nil
    end
    local full_url = base .. (p:sub(1,1) == "/" and p or ("/" .. p))
    local qs = self:_buildQueryString(query)
    full_url = full_url .. qs

    local headers, auth_err = self:_buildAuthHeaders(
        accept_format == "json" and "application/json" or "text/plain")
    if not headers then
        logger.warn("KavitaClient:apiRequest: " .. auth_err)
        return -1, nil, auth_err, nil
    end

    local source

    if type(body) == "table" then
        local payload = rapidjson.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
        source = ltn12.source.string(payload)
    elseif type(body) == "string" then
        headers["Content-Length"] = tostring(#body)
        source = ltn12.source.string(body)
    end

    for k, v in pairs(extra_headers) do headers[k] = v end

    local sink_tbl = {}

    local bt = opts.block_timeout
    local tt = opts.total_timeout
    if not bt or not tt then
        if opts.timeout_profile == "file" then
            bt = socketutil.FILE_BLOCK_TIMEOUT
            tt = socketutil.FILE_TOTAL_TIMEOUT
        else
            bt = socketutil.LARGE_BLOCK_TIMEOUT
            tt = socketutil.LARGE_TOTAL_TIMEOUT
        end
    end
    socketutil:set_timeout(bt, tt)
    local ok, code, resp_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url     = full_url,
            method  = method,
            headers = headers,
            source  = source,
            sink    = ltn12.sink.table(sink_tbl),
        })
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("KavitaClient:apiRequest: LuaSocket error:", code)
        return -1, nil, code, nil
    end

    local body_str = table.concat(sink_tbl)
    return code, resp_headers, status, body_str
end

-- Same as apiRequest, but decodes JSON body on 200-range responses
function KavitaClient:apiJSON(path, opts)
    local code, headers, status, body = self:apiRequest(path, opts)
    if type(code) ~= "number" or code < 200 or code >= 300 then
        return nil, code, headers, status, body
    end
    local s = body or ""
    -- Strip UTF-8 BOM if present
    if #s >= 3 and s:byte(1) == 0xEF and s:byte(2) == 0xBB and s:byte(3) == 0xBF then
        s = s:sub(4)
    end
    -- Trim leading/trailing whitespace
    s = s:match("^%s*(.-)%s*$")

    local ok, decoded = pcall(rapidjson.decode, s)
    if not ok or type(decoded) ~= "table" then
        local ct = headers and (headers["content-type"] or headers["Content-Type"]) or "unknown"
        logger.warn("KavitaClient:apiJSON: JSON decode failed; content-type=", ct)
        return nil, code, headers, "Invalid JSON", body
    end
    return decoded, code, headers, status, body
end

-- Dashboard: GET /api/Stream/dashboard (cached)
function KavitaClient:getDashboard()
    return self:apiJSONCached("/api/Stream/dashboard", {
        method = "GET",
        query  = { visibleOnly = true },
    }, 300, "kavita|dashboard")
end

-- Fetch a Series by id: GET /api/Series/{seriesId}
-- Returns: seriesDto_tbl, code, headers, status, raw_body
function KavitaClient:getSeriesById(seriesId)
    if seriesId == nil then
        logger.warn("KavitaClient:getSeriesById: seriesId is required")
        return nil, nil, nil, "seriesId required", nil
    end
    local path = "/api/Series/" .. tostring(seriesId)
    local data, code, headers, status, body = self:apiJSONCached(path, { method = "GET" }, 600, "kavita|series")
    return data, code, headers, status, body
end

-- Decode an encoded filter string into FilterV2Dto
-- POST /api/Filter/decode
-- Returns: FilterV2Dto table, code, headers, status, raw_body
function KavitaClient:decodeFilter(encodedFilter)
    if not encodedFilter or encodedFilter == "" then
        logger.warn("KavitaClient:decodeFilter: encodedFilter is required")
        return nil, nil, nil, "encodedFilter required", nil
    end

    local data, code, headers, status, body = self:apiJSON("/api/Filter/decode", {
        method = "POST",
        body = {
            encodedFilter = encodedFilter,
        },
    })

    return data, code, headers, status, body
end

-- Fetch a stream's series by name.
-- Uses POST /api/Series/... for known dashboard streams, or decodes and uses smart filters.
-- Returns: array_of_SeriesDto, code, headers, status, raw_body
function KavitaClient:getStreamSeries(name, params)
    if not name or name == "" then
        logger.warn("KavitaClient:getStreamSeries: name is required")
        return nil, nil, nil, "name required", nil
    end

    local method
    local path
    local body
    local query = {}

    -- Extract known paging params if provided
    if type(params) == "table" then
        query.PageNumber = params.PageNumber or params.page or params.pageNumber
        query.PageSize   = params.PageSize   or params.page_size or params.pageSize
        query.libraryId  = params.libraryId
    end

    -- Default FilterV2Dto to include only manga (filter out non-manga)
    -- Caller may override by passing params.filter (a full FilterV2Dto table)
    -- Match the Angular frontend filter structure
    local default_filter_v2 = {
        id = 0,
        name = nil,
        statements = {
            { comparison = 0, field = 21, value = "1" }  -- Format = Archive (manga)
        },
        combination = 1,  -- AND
        limitTo = 0,
        sortOptions = {
            isAscending = false,
            sortField = 4,  -- Recently updated sort
        },
    }
    local filter_v2 = (type(params) == "table" and params.filter) or default_filter_v2

    if name == "on-deck" then
        method = "POST"
        path = "/api/Series/on-deck"
        body = filter_v2
    elseif name == "recently-updated-series" then
        method = "POST"
        path = "/api/Series/all-v2"
        body = filter_v2
    elseif name == "recently-added-v2" then
        method = "POST"
        path = "/api/Series/recently-added-v2"
        body = filter_v2
    elseif name == "want-to-read" then
        method = "POST"
        path = "/api/want-to-read/v2"
        -- Build FilterV2Dto with want-to-read filter
        local want_to_read_filter = {
            id = 0,
            name = nil,
            statements = {
                { comparison = 0, field = 21, value = "1" },  -- Format = Archive (manga)
                { comparison = 0, field = 26, value = "true" }, -- Want to Read = true
            },
            combination = 1, -- AND
            limitTo = 0,
            sortOptions = {
                isAscending = true,
                sortField = 1,
            },
        }
        -- Allow override from params.filter if provided
        body = (type(params) == "table" and params.filter) or want_to_read_filter
    elseif name == "smart-filter" then
        method = "POST"
        path = "/api/Series/all-v2"

        local smartFilterEncoded = type(params) == "table" and params.smartFilterEncoded

        if smartFilterEncoded and smartFilterEncoded ~= "" then
            local decoded_filter, decode_code = self:decodeFilter(smartFilterEncoded)

            if decoded_filter and type(decoded_filter) == "table" then
                body = decoded_filter
            else
                logger.warn("KavitaClient:getStreamSeries: failed to decode smart filter, code:", decode_code)

                return nil, decode_code or -1, nil, "failed to decode smart filter", nil
            end
        else
            logger.warn("KavitaClient:getStreamSeries: smart filter missing smartFilterEncoded")

            return nil, -1, nil, "smart filter missing smartFilterEncoded", nil
        end
    else
        -- Unknown stream name
        logger.warn("KavitaClient:getStreamSeries: unknown stream name:", name)

        return nil, -1, nil, "unknown stream name", nil
    end

    local data, code, headers, status, body_str = self:apiJSONCached(path, {
        method = method,
        query  = query,
        body   = body,
    }, 120, "kavita|stream")

    return data, code, headers, status, body_str
end

-- Fetch the user's reading lists (paginated): POST /api/ReadingList/lists
-- params: { PageNumber, PageSize, includePromoted?, sortByLastModified? }
-- Returns: array_of_ReadingListDto, code, headers, status, raw_body
function KavitaClient:getReadingLists(params)
    local query = {}
    if type(params) == "table" then
        query.PageNumber = params.PageNumber or params.pageNumber or params.page or 1
        query.PageSize   = params.PageSize   or params.pageSize   or params.page_size or 50
        if params.includePromoted ~= nil then
            query.includePromoted = params.includePromoted and "true" or "false"
        end
        if params.sortByLastModified ~= nil then
            query.sortByLastModified = params.sortByLastModified and "true" or "false"
        end
    end

    local data, code, headers, status, body = self:apiJSONCached("/api/ReadingList/lists", {
        method = "POST",
        query  = query,
    }, 120, "kavita|reading-lists")
    return data, code, headers, status, body
end

-- Fetch all items (chapters) of a reading list: GET /api/ReadingList/items?readingListId={id}
-- Note: server flags this call as expensive.
-- Returns: array_of_ReadingListItemDto, code, headers, status, raw_body
function KavitaClient:getReadingListItems(readingListId)
    if readingListId == nil then
        logger.warn("KavitaClient:getReadingListItems: readingListId is required")
        return nil, nil, nil, "readingListId required", nil
    end
    local data, code, headers, status, body = self:apiJSONCached("/api/ReadingList/items", {
        method = "GET",
        query  = { readingListId = readingListId },
    }, 60, "kavita|reading-list-items")
    return data, code, headers, status, body
end

-- Fetch SeriesDetailDto: GET /api/Series/series-detail?seriesId={id}
-- Returns: seriesDetailDto_tbl, code, headers, status, raw_body
function KavitaClient:getSeriesDetail(seriesId)
    if seriesId == nil then
        logger.warn("KavitaClient:getSeriesDetail: seriesId is required")
        return nil, nil, nil, "seriesId required", nil
    end
    local path = "/api/Series/series-detail"
    local data, code, headers, status, body = self:apiJSON(path, {
        method = "GET",
        query  = { seriesId = seriesId },
    })
    return data, code, headers, status, body
end

-- Returns the file dimensions for all pages in a chapter.
-- GET /api/Reader/file-dimensions?chapterId={id}&extractPdf=false[&apiKey=...]
function KavitaClient:getFileDimensions(chapter_id)
    if not chapter_id then
        logger.warn("KavitaClient:getFileDimensions: chapter_id is required")
        return nil, -1, nil, "chapterId required", nil
    end
    local query = {
        chapterId  = chapter_id,
        extractPdf = false,
    }
    if self.api_key and self.api_key ~= "" then
        query.apiKey = self.api_key
    end
    local data, code, headers, status, body = self:apiJSONCached("/api/Reader/file-dimensions", {
        method          = "GET",
        query           = query,
        timeout_profile = "file",
    }, 600, "kavita|filedims")
    return data, code, headers, status, body
end

-- Build a complete socket.http-style request table for a Reader /image fetch.
-- Auth + base headers come from the shared _buildAuthHeaders helper (same as
-- _apiRequestImpl), so the async non-blocking fetch client issues an
-- identical request. Returns {url, method, headers} (caller supplies sink).
function KavitaClient:buildImageRequestTable(chapter_id, page0)
    if not self.base_url then
        return nil, "Missing base_url"
    end
    local query = {
        chapterId  = chapter_id,
        page       = page0,
        extractPdf = "false",
    }
    -- Some deployments require apiKey as a query param in addition to Bearer
    if self.api_key and self.api_key ~= "" then
        query.apiKey = self.api_key
    end

    local base = self.base_url:gsub("/+$", "")
    local full_url = base .. "/api/Reader/image" .. self:_buildQueryString(query)

    local headers, auth_err = self:_buildAuthHeaders("*/*")
    if not headers then
        return nil, auth_err
    end

    return {
        url = full_url,
        method = "GET",
        headers = headers,
    }
end

-- Creates a page table for Kavita Reader images.
-- Page images are fetched on demand by the async non-blocking client
-- (kamareasyncfetch.lua); the page count is supplied separately by the viewer
-- via VirtualImageDocument's pages_override, so this table is now just a
-- metadata carrier (no lazy per-page supplier).
function KavitaClient:createReaderPageTable(_chapter_id, _ctx)
    return { image_disposable = true }
end

-- Convenience wrapper to return page table
function KavitaClient:streamChapter(chapter_id)
    local page_table = self:createReaderPageTable(chapter_id)
    return page_table
end

-- Save page progress for authenticated user: POST /api/Reader/progress
-- progress = { volumeId, chapterId, pageNum, seriesId, libraryId, bookScrollId?, lastModifiedUtc? }
function KavitaClient:postReaderProgress(progress)
    if type(progress) ~= "table" then
        logger.warn("KavitaClient:postReaderProgress: progress must be table")
        return -1, nil, "invalid progress", nil
    end
    if not (progress.volumeId and progress.chapterId and progress.pageNum and progress.seriesId and progress.libraryId) then
        logger.warn("KavitaClient:postReaderProgress: missing required fields")
        return -1, nil, "invalid progress", nil
    end
    return self:apiRequest("/api/Reader/progress", {
        method = "POST",
        body = progress,
    })
end

-- Convenience wrapper to post progress for a specific page number given a context table.
-- ctx may use snake_case or camelCase keys.
function KavitaClient:postReaderProgressForPage(ctx, pageNum)
    if type(ctx) ~= "table" or type(pageNum) ~= "number" then
        logger.warn("KavitaClient:postReaderProgressForPage: invalid ctx or pageNum")
        return -1, nil, "invalid progress ctx", nil
    end
    local payload = {
        volumeId  = ctx.volume_id or ctx.volumeId,
        chapterId = ctx.chapter_id or ctx.chapterId,
        pageNum   = pageNum,
        seriesId  = ctx.series_id or ctx.seriesId,
        libraryId = ctx.library_id or ctx.libraryId,
    }
    return self:postReaderProgress(payload)
end

-- Async equivalent of postReaderProgressForPage. Runs the POST through the
-- non-blocking AsyncFetch client so UIManager keeps processing input/paint
-- during the round-trip (the sync version blocks ~300ms). Used for the
-- debounced progress post during active reading; the close path stays sync
-- to guarantee delivery before teardown.
--
-- on_done(body, code) is invoked once on completion (success or failure).
-- Errors are logged but not raised; callers must not depend on the POST
-- succeeding for correctness (progress is best-effort).
function KavitaClient:postReaderProgressForPageAsync(ctx, pageNum, on_done)
    on_done = on_done or function() end
    if type(ctx) ~= "table" or type(pageNum) ~= "number" then
        logger.warn("KavitaClient:postReaderProgressForPageAsync: invalid ctx or pageNum")
        on_done(nil, -1)
        return
    end
    if not self.base_url then
        logger.warn("KavitaClient:postReaderProgressForPageAsync: missing base_url")
        on_done(nil, -1)
        return
    end

    local payload = {
        volumeId  = ctx.volume_id or ctx.volumeId,
        chapterId = ctx.chapter_id or ctx.chapterId,
        pageNum   = pageNum,
        seriesId  = ctx.series_id or ctx.seriesId,
        libraryId = ctx.library_id or ctx.libraryId,
    }
    local body = rapidjson.encode(payload)

    local base = self.base_url:gsub("/+$", "")
    local headers, auth_err = self:_buildAuthHeaders("application/json")
    if not headers then
        logger.warn("KavitaClient:postReaderProgressForPageAsync: " .. auth_err)
        on_done(nil, -1)
        return
    end
    headers["Content-Type"] = "application/json"

    local req = {
        url     = base .. "/api/Reader/progress",
        method  = "POST",
        headers = headers,
        body    = body,
    }
    return AsyncFetch.fetch(req, { quantum_ms = 60 }, function(resp_body, code, stats)
        if code == 200 then
            logger.dbg(string.format("[kamare:progress] async POST ok page=%d", pageNum))
        else
            logger.dbg(string.format("[kamare:progress] async POST code=%s err=%s page=%d",
                tostring(code), stats and stats.err or "-", pageNum))
        end
        on_done(resp_body, code)
    end)
end

-- Search: GET /api/Search/search
-- params: { queryString = "...", includeChapterAndFiles = false }
-- Returns: SearchResultGroupDto table on success
function KavitaClient:getSearch(queryString, includeChapterAndFiles)
    if not queryString or queryString == "" then
        logger.warn("KavitaClient:getSearch: empty queryString")
        return nil, nil, nil, "empty query", nil
    end
    local path = "/api/Search/search"
    local params = {
        queryString = queryString,
        includeChapterAndFiles = includeChapterAndFiles == nil and false or includeChapterAndFiles,
    }
    local data, code, headers, status, body = self:apiJSONCached(path, {
        method = "GET",
        query  = params,
    }, 120, "kavita|search")
    return data, code, headers, status, body
end

-- Fetch the continue point chapter for a series: GET /api/Reader/continue-point?seriesId={id}
-- Returns: chapterDto_tbl, code, headers, status, raw_body
function KavitaClient:getContinuePoint(seriesId)
    if seriesId == nil then
        logger.warn("KavitaClient:getContinuePoint: seriesId is required")
        return nil, nil, nil, "seriesId required", nil
    end
    local path = "/api/Reader/continue-point"
    local data, code, headers, status, body = self:apiJSON(path, {
        method = "GET",
        query  = { seriesId = seriesId },
    })
    return data, code, headers, status, body
end

-- Fetch the next logical chapter from a series: GET /api/Reader/next-chapter
-- Returns: chapterId (integer), code, headers, status, raw_body
function KavitaClient:getNextChapter(seriesId, volumeId, currentChapterId)
    if not seriesId or not volumeId or not currentChapterId then
        logger.warn("KavitaClient:getNextChapter: seriesId, volumeId, and currentChapterId are required")
        return nil, nil, nil, "seriesId, volumeId, and currentChapterId required", nil
    end
    local path = "/api/Reader/next-chapter"
    -- Use apiRequest instead of apiJSON since response is plain text (number)
    local code, headers, status, body = self:apiRequest(path, {
        method = "GET",
        query  = {
            seriesId = seriesId,
            volumeId = volumeId,
            currentChapterId = currentChapterId,
        },
    })

    -- Parse the body as a plain number
    if type(code) == "number" and code >= 200 and code < 300 and body then
        local chapter_id = tonumber(body)
        if chapter_id then
            return chapter_id, code, headers, status, body
        else
            logger.warn("KavitaClient:getNextChapter: failed to parse body as number:", body)
            return nil, code, headers, "Invalid response body", body
        end
    end

    return nil, code, headers, status, body
end

-- Fetch series cover image: GET /api/Image/series-cover?seriesId={id}&apiKey={key}
-- Returns: raw image data (binary), code, headers, status
function KavitaClient:getSeriesCover(seriesId)
    if not seriesId then
        logger.warn("KavitaClient:getSeriesCover: seriesId is required")
        return nil, -1, nil, "seriesId required"
    end
    if not self.api_key then
        logger.warn("KavitaClient:getSeriesCover: api_key not set")
        return nil, -1, nil, "api_key required"
    end

    local code, headers, status, body = self:apiRequest("/api/Image/series-cover", {
        method = "GET",
        query  = {
            seriesId = seriesId,
            apiKey = self.api_key,
        },
    })

    if type(code) == "number" and code >= 200 and code < 300 then
        return body, code, headers, status
    else
        logger.warn("KavitaClient:getSeriesCover: failed to fetch cover for series", seriesId,
                   "code:", code, "status:", status)
        return nil, code, headers, status
    end
end

-- Fetch volume cover image: GET /api/Image/volume-cover?volumeId={id}&apiKey={key}
-- Returns: raw image data (binary), code, headers, status
function KavitaClient:getVolumeCover(volumeId)
    if not volumeId then
        logger.warn("KavitaClient:getVolumeCover: volumeId is required")
        return nil, -1, nil, "volumeId required"
    end
    if not self.api_key then
        logger.warn("KavitaClient:getVolumeCover: api_key not set")
        return nil, -1, nil, "api_key required"
    end

    local code, headers, status, body = self:apiRequest("/api/Image/volume-cover", {
        method = "GET",
        query  = {
            volumeId = volumeId,
            apiKey = self.api_key,
        },
    })

    if type(code) == "number" and code >= 200 and code < 300 then
        return body, code, headers, status
    else
        logger.warn("KavitaClient:getVolumeCover: failed to fetch cover for volume", volumeId,
                   "code:", code, "status:", status)
        return nil, code, headers, status
    end
end

-- Fetch chapter cover image: GET /api/Image/chapter-cover?chapterId={id}&apiKey={key}
-- Returns: raw image data (binary), code, headers, status
function KavitaClient:getChapterCover(chapterId)
    if not chapterId then
        logger.warn("KavitaClient:getChapterCover: chapterId is required")
        return nil, -1, nil, "chapterId required"
    end
    if not self.api_key then
        logger.warn("KavitaClient:getChapterCover: api_key not set")
        return nil, -1, nil, "api_key required"
    end

    local code, headers, status, body = self:apiRequest("/api/Image/chapter-cover", {
        method = "GET",
        query  = {
            chapterId = chapterId,
            apiKey = self.api_key,
        },
    })

    if type(code) == "number" and code >= 200 and code < 300 then
        return body, code, headers, status
    else
        logger.warn("KavitaClient:getChapterCover: failed to fetch cover for chapter", chapterId,
                   "code:", code, "status:", status)
        return nil, code, headers, status
    end
end

-- Fetch series metadata: GET /api/Series/metadata?seriesId={id}
-- Returns: SeriesMetadataDto with summary, language, writers, genres, tags, etc.
function KavitaClient:getSeriesMetadata(seriesId)
    if not seriesId then
        logger.warn("KavitaClient:getSeriesMetadata: seriesId is required")
        return nil, nil, nil, "seriesId required", nil
    end

    local data, code, headers, status, body = self:apiJSONCached("/api/Series/metadata", {
        method = "GET",
        query  = { seriesId = seriesId },
    }, 600, "kavita|metadata")

    if not data then
        logger.warn("KavitaClient:getSeriesMetadata: failed to fetch metadata for series", seriesId,
                   "code:", code, "status:", status)
    end

    return data, code, headers, status, body
end

-- Fetch volume metadata: GET /api/Volume?volumeId={id}
-- Returns: VolumeDto table, code, headers, status, raw_body
function KavitaClient:getVolumeById(volumeId)
    if not volumeId then
        logger.warn("KavitaClient:getVolumeById: volumeId is required")
        return nil, nil, nil, "volumeId required", nil
    end

    local data, code, headers, status, body = self:apiJSONCached("/api/Volume", {
        method = "GET",
        query  = { volumeId = volumeId },
    }, 600, "kavita|volume")

    if not data then
        logger.warn("KavitaClient:getVolumeById: failed to fetch volume", volumeId,
            "code:", code, "status:", status)
    end

    return data, code, headers, status, body
end

-- Fetch chapter metadata: GET /api/Chapter?chapterId={id}
-- Returns: ChapterDto table, code, headers, status, raw_body
function KavitaClient:getChapterById(chapterId)
    if not chapterId then
        logger.warn("KavitaClient:getChapterById: chapterId is required")
        return nil, nil, nil, "chapterId required", nil
    end

    local data, code, headers, status, body = self:apiJSONCached("/api/Chapter", {
        method = "GET",
        query  = { chapterId = chapterId },
    }, 600, "kavita|chapter")

    if not data then
        logger.warn("KavitaClient:getChapterById: failed to fetch chapter", chapterId,
            "code:", code, "status:", status)
    end

    return data, code, headers, status, body
end

-- Get Kavita server version: GET /api/Plugin/version?apiKey={key}
-- Returns: version string, code, headers, status
function KavitaClient:getKavitaVersion()
    if not self.api_key then
        logger.warn("KavitaClient:getKavitaVersion: api_key not set")
        return nil, -1, nil, "api_key required", nil
    end

    -- The API returns plain text, not JSON
    local code, headers, status, body = self:apiRequest("/api/Plugin/version", {
        method = "GET",
        query  = { apiKey = self.api_key },
        accept_format = "text",
    })

    if type(code) == "number" and code >= 200 and code < 300 then
        logger.info("KavitaClient:getKavitaVersion: fetched version:", body)
        return body, code, headers, status, body
    else
        logger.warn("KavitaClient:getKavitaVersion: failed to fetch version", "code:", code, "status:", status)
        return nil, code, headers, status, body
    end
end

return KavitaClient
