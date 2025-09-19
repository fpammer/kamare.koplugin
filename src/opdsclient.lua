local Cache = require("cache")
local OPDSParser = require("opdsparser")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local Screen = require("device").screen
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local _ = require("gettext")

-- cache catalog parsed from feed xml
local FeedCache = Cache:new{
    -- Make it 20 slots, with no storage space constraints
    slots = 20,
}

local OPDSClient = {}

OPDSClient.catalog_type = "application/atom%+xml"
OPDSClient.search_type = "application/opensearchdescription%+xml"
OPDSClient.search_template_type = "application/atom%+xml"

function OPDSClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function OPDSClient:fetchFeed(item_url, headers_only, username, password)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local request = {
        url      = item_url,
        method   = headers_only and "HEAD" or "GET",
        headers  = {
            ["Accept-Encoding"] = "identity",
        },
        sink     = ltn12.sink.table(sink),
        user     = username,
        password = password,
    }

    -- Capture potential LuaSocket errors
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)

    socketutil:reset_timeout()

    if not ok then
        -- pcall caught an error (likely network/SSL issue)
        return nil, -1, nil, code  -- Use -1 to indicate a network error
    end

    if headers_only then
        return headers
    end

    if code == 200 then
        local xml = table.concat(sink)
        return xml ~= "" and xml or nil, code, headers, status
    else
        return nil, code, headers, status
    end
end

function OPDSClient:parseFeed(item_url, username, password)
    -- Check cache FIRST before making any network requests
    local hash = "opds|catalog|" .. item_url

    -- Check if we have a cached version and if it's still fresh (5 minutes)
    local ok, cached_data = pcall(FeedCache.check, FeedCache, hash)
    if ok and cached_data then
        local cache_age = os.time() - (cached_data.timestamp or 0)
        if cache_age < 300 then -- 5 minutes
            return cached_data.feed
        end
    end

    -- Only make HTTP request if cache miss or stale
    local feed, code, headers, status = self:fetchFeed(item_url, false, username, password)
    if not feed or (code ~= 200 and code ~= -1) then
        return nil, code, headers, status
    end
    if code == -1 then
        -- Network error, status contains the error message
        return nil, code, headers, status
    end

    -- Parse the fetched feed
    local ok, parsed_feed_or_error = pcall(OPDSParser.parse, OPDSParser, feed)

    if not ok then
        return nil, code, headers, status
    end

    -- Store both the feed and a timestamp for freshness checking
    local cache_data = {
        feed = parsed_feed_or_error,
        timestamp = os.time()
    }
    local ok, cache_error = pcall(FeedCache.insert, FeedCache, hash, cache_data)
    if not ok then
        logger.warn("OPDSClient:parseFeed - Cache insertion failed:", cache_error)
    end

    -- Extract OpenSearch metadata if available
    if parsed_feed_or_error and parsed_feed_or_error.feed then
        local feed = parsed_feed_or_error.feed
        local opensearch_data = {}

        for key, value in pairs(feed) do
            if type(key) == "string" then
                -- Check for OpenSearch elements with namespace prefix
                if key == "opensearch:totalResults" or key == "totalResults" then
                    opensearch_data.totalResults = tonumber(value) or 0
                elseif key == "opensearch:itemsPerPage" or key == "itemsPerPage" then
                    opensearch_data.itemsPerPage = tonumber(value) or 20
                elseif key == "opensearch:startIndex" or key == "startIndex" then
                    opensearch_data.startIndex = tonumber(value) or 1
                end
            end
        end

        -- If we found any OpenSearch data, add it to the parsed feed
        if next(opensearch_data) ~= nil then
            parsed_feed_or_error.opensearch = opensearch_data
        end
    end

    return parsed_feed_or_error
end

-- Generates link to search in catalog
function OPDSClient:getSearchTemplate(osd_url, username, password)
    -- Cache search templates separately since they rarely change
    local search_hash = "opds|search_template|" .. osd_url

    -- Check cache first
    local ok, cached_template = pcall(FeedCache.check, FeedCache, search_hash)
    if ok and cached_template then
        local cache_age = os.time() - (cached_template.timestamp or 0)
        if cache_age < 86400 then -- 24 hours
            return cached_template.template
        end
    end

    -- parse search descriptor
    local search_descriptor = self:parseFeed(osd_url, username, password)
    local search_template = nil

    if search_descriptor and search_descriptor.OpenSearchDescription and search_descriptor.OpenSearchDescription.Url then
        for _, candidate in ipairs(search_descriptor.OpenSearchDescription.Url) do
            if candidate.type and candidate.template and candidate.type:find(self.search_template_type) then
                search_template = candidate.template:gsub("{searchTerms}", "%%s")
                break
            end
        end
    end

    -- Cache the search template
    if search_template then
        local cache_data = {
            template = search_template,
            timestamp = os.time()
        }
        local ok, cache_error = pcall(FeedCache.insert, FeedCache, search_hash, cache_data)
        if not ok then
            logger.warn("OPDSClient:getSearchTemplate - Cache insertion failed:", cache_error)
        end
    end

    return search_template
end

-- Creates a page table metatable for streaming images from an OPDS server
function OPDSClient:createPageTable(remote_url, username, password)
    local page_table = {image_disposable = true}
    setmetatable(page_table, {__index = function (_, key)
        if type(key) ~= "number" then
            return nil
        end

        local index = key - 1
        local page_url = remote_url:gsub("{pageNumber}", tostring(index))
        page_url = page_url:gsub("{maxWidth}", tostring(Screen:getWidth()))
        local page_data = {}

        logger.dbg("Streaming page from", page_url)
        local parsed = url.parse(page_url)

        local code, headers, status
        if parsed.scheme == "http" or parsed.scheme == "https" then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            code, headers, status = socket.skip(1, http.request {
                url         = page_url,
                headers     = {
                    ["Accept-Encoding"] = "identity",
                },
                sink        = ltn12.sink.table(page_data),
                user        = username,
                password    = password,
            })
            socketutil:reset_timeout()
        end

        if code == 200 then
            return table.concat(page_data)
        else
            logger.dbg("OPDSClient: Request failed:", status or code)
            return nil
        end
    end})
    return page_table
end

-- Main streaming function - returns page table and total page count
function OPDSClient:streamPages(remote_url, count, username, password)
    local page_table = self:createPageTable(remote_url, username, password)
    return page_table, count
end

return OPDSClient
