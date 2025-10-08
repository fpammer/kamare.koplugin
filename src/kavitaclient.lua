local Cache = require("cache")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local rapidjson = require("rapidjson")
local md5 = require("ffi/sha2").md5

-- Redact sensitive query params in debug logs
local function redact_api_key_in_url(u)
    if type(u) ~= "string" then return u end
    return (u:gsub("([?&]apiKey=)[^&]+", "%1REDACTED"))
end

local ApiCache = Cache:new{
    slots = 20,
}

local KavitaClient = {}


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

-- Generic API request with Authorization: Bearer
-- Returns: code, headers, status, body_string
function KavitaClient:apiRequest(path, opts)
    opts = opts or {}
    local method = opts.method or "GET"
    local query = opts.query
    local body = opts.body
    local extra_headers = opts.headers or {}

    if not self.base_url or not self.bearer then
        logger.warn("KavitaClient:apiRequest: missing base_url or bearer")
        return -1, nil, "Missing base_url or bearer", nil
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

    local headers = {
        ["Accept"] = "application/json",
        ["Authorization"] = "Bearer " .. self.bearer,
        ["Accept-Encoding"] = "identity",
    }
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

-- Fetch a stream’s series by name.
-- Uses POST /api/Series/... for known dashboard streams, otherwise falls back to GET /api/Stream/{name}.
-- Returns: array_of_SeriesDto, code, headers, status, raw_body
function KavitaClient:getStreamSeries(name, params)
    if not name or name == "" then
        logger.warn("KavitaClient:getStreamSeries: name is required")
        return nil, nil, nil, "name required", nil
    end

    local method = "GET"
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
    local default_filter_v2 = { statements = { { comparison = 0, field = 21, value = "1" } } }
    local filter_v2 = (type(params) == "table" and params.filter) or default_filter_v2

    if name == "on-deck" then
        method = "POST"
        path = "/api/Series/on-deck"
        body = filter_v2
    elseif name == "recently-updated" or name == "recently-updated-series" then
        method = "POST"
        path = "/api/Series/recently-updated-series"
        body = filter_v2
    elseif name == "newly-added" or name == "recently-added" or name == "recently-added-v2" then
        method = "POST"
        path = "/api/Series/recently-added-v2"
        body = filter_v2
    elseif name == "want-to-read" then
        method = "POST"
        path = "/api/want-to-read/v2"
        -- Build FilterV2Dto with want-to-read filter
        local want_to_read_filter = {
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
    else
        -- Fallback to Stream endpoint
        method = "GET"
        path = "/api/Stream/" .. tostring(name)
        if type(params) == "table" then
            for k, v in pairs(params) do
                if query[k] == nil then query[k] = v end
            end
        end
        if query.visibleOnly == nil then query.visibleOnly = true end
    end

    local data, code, headers, status, body_str = self:apiJSONCached(path, {
        method = method,
        query  = query,
        body   = body,
    }, 120, "kavita|stream")
    return data, code, headers, status, body_str
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

-- Creates a page table for Kavita Reader images
function KavitaClient:createReaderPageTable(chapter_id, ctx)
    local page_table = { image_disposable = true }

    setmetatable(page_table, { __index = function(_, key)
        if type(key) ~= "number" then
            return nil
        end
        -- Our page_table is 1-based (Lua). Kavita Reader /image uses 0-based page index.
        local page1 = key
        local page0 = math.max(0, (page1 or 1) - 1)

        -- Build query
        local query = {
            chapterId  = chapter_id,
            page       = page0,
            extractPdf = "false",
        }
        -- Some deployments require apiKey as query param in addition to Bearer
        if self.api_key and self.api_key ~= "" then
            query.apiKey = self.api_key
        end

        local code, _, status, body_str = self:apiRequest("/api/Reader/image", {
            method  = "GET",
            query   = query,
            headers = { ["Accept"] = "*/*" },
            timeout_profile = "file",
        })

        if type(code) ~= "number" or code ~= 200 then
            return nil
        end

        -- No reading progress side-effects here; handled by viewer when page is shown
        return body_str
    end })

    return page_table
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

return KavitaClient
