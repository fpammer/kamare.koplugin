local logger = require("logger")
local KavitaClient = require("kavitaclient")
local Utils = require("kamareutils")
local RenderImage = require("ui/renderimage")
local zstd = require("ffi/zstd")
local SQ3 = require("lua-ljsqlite3/init")
local DocumentRegistry = require("document/documentregistry")
local util = require("util")

local BookInfoManagerHook = {}

-- Original functions (saved when hook is installed)
local original_getBookInfo = nil
local original_getDocProps = nil
local original_extractBookInfo = nil

-- Minimal Kavita document provider
-- This exists to make DocumentRegistry:hasProvider() return true for .kavita files
-- It doesn't actually open documents - that's handled by KamareImageViewer
local KavitaProvider = {
    provider = "kavita_provider",
}

function KavitaProvider:new(file_path)
    -- This should never be called since we intercept at the BookInfoManager level
    -- But if it is, return nil to indicate we can't actually open the document
    logger.warn("KavitaProvider:new() called - this shouldn't happen!")
    logger.warn("  file_path:", file_path)
    return nil
end

-- Helper: Check if a filepath is a Kavita virtual path
local function isKavitaPath(filepath)
    if not filepath or type(filepath) ~= "string" then
        return false
    end
    -- Match pattern: /kavita/{server}/{type}/{id}.kavita
    return filepath:match("^/kavita/[^/]+/[^/]+/%d+%.kavita$") ~= nil
end

-- Helper: Parse Kavita virtual path
-- Returns: server_name, item_type, item_id
local function parseKavitaPath(filepath)
    local server, item_type, item_id = filepath:match("^/kavita/([^/]+)/([^/]+)/(%d+)%.kavita$")
    if server and item_type and item_id then
        return server, item_type, tonumber(item_id)
    end
    return nil, nil, nil
end

-- Helper: Fetch metadata from Kavita API
local function fetchKavitaMetadata(filepath)
    local server_name, item_type, item_id = parseKavitaPath(filepath)
    if not server_name or not item_type or not item_id then
        logger.warn("Kamare: Failed to parse Kavita path:", filepath)
        return nil
    end

    -- Fetch metadata based on item type
    if item_type == "series" then
        local series_metadata, code = KavitaClient:getSeriesMetadata(item_id)
        if not series_metadata or code ~= 200 then
            logger.warn("Kamare: Failed to fetch series metadata for:", item_id, "code:", code)
            return nil
        end

        -- Also fetch SeriesDto for pages count and name
        local series_dto, code2 = KavitaClient:getSeriesById(item_id)
        if not series_dto or code2 ~= 200 then
            logger.warn("Kamare: Failed to fetch series DTO for:", item_id, "code:", code2)
            return nil
        end

        -- Extract authors from writers array
        local authors = {}
        if series_metadata.writers then
            for _, writer in ipairs(series_metadata.writers) do
                if writer.name then
                    table.insert(authors, writer.name)
                end
            end
        end
        local authors_str = table.concat(authors, ", ")

        -- Extract genres and tags for keywords
        local keywords = {}
        if series_metadata.genres then
            for _, genre in ipairs(series_metadata.genres) do
                if genre.tag then
                    table.insert(keywords, genre.tag)
                end
            end
        end
        if series_metadata.tags then
            for _, tag in ipairs(series_metadata.tags) do
                if tag.title then
                    table.insert(keywords, tag.title)
                end
            end
        end
        local keywords_str = table.concat(keywords, ", ")

        return {
            pages = series_dto.pages or 0,
            title = Utils.firstNonEmpty(series_dto.localizedName, series_dto.name) or "",
            authors = authors_str,
            series = Utils.firstNonEmpty(series_dto.name, series_dto.localizedName),
            series_index = nil,  -- Series itself has no index
            language = series_metadata.language or "en",
            keywords = Utils.firstNonEmpty(keywords_str),
            description = type(series_metadata.summary) == "string" and series_metadata.summary or nil,
        }

    elseif item_type == "volume" then
        local volume_metadata, code = KavitaClient:getVolumeById(item_id)
        if not volume_metadata or code ~= 200 then
            logger.warn("Kamare: Failed to fetch volume metadata for:", item_id, "code:", code)
            return nil
        end

        local title = Utils.buildVolumeTitle(volume_metadata)

        return {
            pages = volume_metadata.pages or 0,
            title = title,
            authors = "",
            series = Utils.firstNonEmpty(volume_metadata.seriesName) or "",
            series_index = volume_metadata.number,
            language = "en",
            keywords = nil,
            description = type(volume_metadata.summary) == "string" and volume_metadata.summary or nil,
        }

    elseif item_type == "chapter" then
        local chapter_metadata, code = KavitaClient:getChapterById(item_id)
        if not chapter_metadata or code ~= 200 then
            logger.warn("Kamare: Failed to fetch chapter metadata for:", item_id, "code:", code)
            return nil
        end

        local title = Utils.buildChapterTitle(chapter_metadata)

        return {
            pages = chapter_metadata.pages or 0,
            title = title,
            authors = "",
            series = Utils.firstNonEmpty(chapter_metadata.seriesName) or "",
            series_index = chapter_metadata.number,
            language = "en",
            keywords = nil,
            description = type(chapter_metadata.summary) == "string" and chapter_metadata.summary or nil,
        }
    end

    return nil
end

-- Helper: Calculate cached cover size while maintaining aspect ratio
-- (mirrors BookInfoManager.getCachedCoverSize; kept local to avoid a _G global)
local function getCachedCoverSize(img_w, img_h, max_img_w, max_img_h)
    local scale_factor
    local width = math.floor(max_img_h * img_w / img_h + 0.5)
    if max_img_w >= width then
        max_img_w = width
        scale_factor = max_img_w / img_w
    else
        max_img_h = math.floor(max_img_w * img_h / img_w + 0.5)
        scale_factor = max_img_h / img_h
    end
    return max_img_w, max_img_h, scale_factor
end

-- Helper: Fetch and process cover image from Kavita API
local function fetchKavitaCover(item_type, item_id, cover_specs)
    -- Get cover specs (default to 600x600 like BookInfoManager)
    local max_cover_w = (cover_specs and cover_specs.max_cover_w) or 600
    local max_cover_h = (cover_specs and cover_specs.max_cover_h) or 600

    -- Call appropriate cover API based on item type
    local cover_data, code
    if item_type == "series" then
        cover_data, code = KavitaClient:getSeriesCover(item_id)
    elseif item_type == "volume" then
        cover_data, code = KavitaClient:getVolumeCover(item_id)
    elseif item_type == "chapter" then
        cover_data, code = KavitaClient:getChapterCover(item_id)
    end

    if not cover_data or code ~= 200 then
        return nil
    end

    -- Load image data into BlitBuffer using renderImageData()
    local cover_bb = RenderImage:renderImageData(cover_data, #cover_data)
    if not cover_bb then
        logger.warn("Kamare: Failed to decode cover image")
        return nil
    end

    local original_w = cover_bb.w
    local original_h = cover_bb.h

    -- Scale if larger than max dimensions (reuse BookInfoManager logic)
    if original_w > max_cover_w or original_h > max_cover_h then
        local new_w, new_h = getCachedCoverSize(
            original_w, original_h, max_cover_w, max_cover_h
        )
        cover_bb = RenderImage:scaleBlitBuffer(cover_bb, new_w, new_h, true)
    end

    -- Extract BlitBuffer metadata (direct field access, not methods)
    local width = cover_bb.w
    local height = cover_bb.h
    local bbtype = cover_bb:getType()
    local stride = tonumber(cover_bb.stride)

    -- Compress image data (reuse BookInfoManager pattern)
    local cover_size = stride * height
    local cover_zst_ptr, cover_zst_size = zstd.zstd_compress(cover_bb.data, cover_size)

    -- Cast to SQLite blob (same as BookInfoManager)
    local compressed_data = SQ3.blob(cover_zst_ptr, cover_zst_size)

    -- Free the BlitBuffer
    cover_bb:free()

    -- Verify compressed_data is valid
    if not compressed_data or tonumber(cover_zst_size) == 0 then
        logger.warn("Kamare: Invalid compressed cover data")
        return nil
    end

    return {
        width = width,
        height = height,
        bb_type = bbtype,
        bb_stride = stride,
        bb_data = compressed_data,
    }
end

-- Overridden getBookInfo function
local function hooked_getBookInfo(self, filepath, do_cover_image)
    -- Check if this is a Kavita path
    if isKavitaPath(filepath) then
        -- Now that we've registered .kavita with DocumentRegistry, the original
        -- getBookInfo() will pass the hasProvider() check and query the database normally
        return original_getBookInfo(self, filepath, do_cover_image)
    end

    -- Not a Kavita path - use original implementation
    return original_getBookInfo(self, filepath, do_cover_image)
end

-- Overridden extractBookInfo function
local function hooked_extractBookInfo(self, filepath, cover_specs)
    -- Check if this is a Kavita path
    if isKavitaPath(filepath) then
        -- Parse the virtual path
        local _, item_type, item_id = parseKavitaPath(filepath)

        -- Fetch metadata from Kavita API
        local metadata = fetchKavitaMetadata(filepath)
        if not metadata then
            logger.warn("Kamare: Failed to fetch Kavita metadata for:", filepath)
            return false
        end

        -- Fetch cover if requested
        local cover_data = nil
        if cover_specs then
            cover_data = fetchKavitaCover(item_type, item_id, cover_specs)
        end

        -- Build complete dbrow structure (all 25 columns)
        local directory, filename = util.splitFilePathName(filepath)

        -- Only set has_cover if we have complete cover data
        local has_cover = (cover_data and cover_data.bb_data) and "Y" or nil

        -- Store original cover size (before any scaling)
        local cover_sizetag = nil
        if has_cover then
            cover_sizetag = cover_data.width .. "x" .. cover_data.height
        end

        local dbrow = {
            -- File identification
            directory = directory,
            filename = filename,
            filesize = 0,  -- Virtual file, no size
            filemtime = os.time(),  -- Current time

            -- Extraction status
            in_progress = 0,  -- Completed
            unsupported = nil,  -- Supported
            cover_fetched = "Y",  -- Tried to fetch
            has_meta = "Y",  -- Has metadata
            has_cover = has_cover,  -- Only if we have valid blob data
            cover_sizetag = cover_sizetag,  -- "WxH" format
            ignore_meta = nil,  -- Don't ignore
            ignore_cover = nil,  -- Don't ignore

            -- Metadata from Kavita API
            pages = metadata.pages,
            title = metadata.title,
            authors = metadata.authors,
            series = metadata.series,
            series_index = metadata.series_index,
            language = metadata.language,
            keywords = metadata.keywords,
            description = metadata.description,

            -- Cover fields (from API) - only set if has_cover is set
            cover_w = has_cover and cover_data.width or nil,
            cover_h = has_cover and cover_data.height or nil,
            cover_bb_type = has_cover and cover_data.bb_type or nil,
            cover_bb_stride = has_cover and cover_data.bb_stride or nil,
            cover_bb_data = has_cover and cover_data.bb_data or nil,
        }

        -- Write to database using prepared INSERT OR REPLACE statement
        self:openDbConnection()

        -- Need to get BOOKINFO_COLS_SET to know the column order
        -- It's local in bookinfomanager.lua, so we need to reconstruct it
        local BOOKINFO_COLS_SET = {
            "directory", "filename", "filesize", "filemtime",
            "in_progress", "unsupported", "cover_fetched",
            "has_meta", "has_cover", "cover_sizetag",
            "ignore_meta", "ignore_cover",
            "pages", "title", "authors", "series", "series_index",
            "language", "keywords", "description",
            "cover_w", "cover_h", "cover_bb_type", "cover_bb_stride", "cover_bb_data"
        }

        for num, col in ipairs(BOOKINFO_COLS_SET) do
            self.set_stmt:bind1(num, dbrow[col])
        end
        self.set_stmt:step()
        self.set_stmt:clearbind():reset()

        return true  -- Successfully loaded/extracted
    end

    -- Not a Kavita path - use original implementation
    return original_extractBookInfo(self, filepath, cover_specs)
end

-- Overridden getDocProps function
local function hooked_getDocProps(self, filepath)
    -- Check if this is a Kavita path
    if isKavitaPath(filepath) then
        -- First, check if we already have cached data
        local cached = original_getDocProps(self, filepath)
        if cached then
            return cached
        end

        -- Cache miss - fetch from Kavita API
        local metadata = fetchKavitaMetadata(filepath)

        if metadata then
            -- Write to cache using setBookInfoProperties
            self:setBookInfoProperties(filepath, metadata)
            return metadata
        else
            logger.warn("Kamare: Failed to fetch metadata for:", filepath)
            return nil
        end
    end

    -- Not a Kavita path - use original implementation
    return original_getDocProps(self, filepath)
end

-- Install the hook
function BookInfoManagerHook:install(kamare_instance)
    local BookInfoManager = kamare_instance.BookInfoManager

    if not BookInfoManager then
        logger.warn("Kamare: BookInfoManager not available, cannot install hook")
        return false
    end

    if original_getBookInfo and original_getDocProps and original_extractBookInfo then
        logger.warn("Kamare: BookInfoManager hooks already installed")
        return true
    end

    -- Register .kavita extension with DocumentRegistry
    -- This makes DocumentRegistry:hasProvider() return true for .kavita files
    -- so BookInfoManager will query the database instead of returning a stub
    DocumentRegistry:addProvider("kavita", "application/x-kavita", KavitaProvider, 100)

    -- Save original functions
    original_getBookInfo = BookInfoManager.getBookInfo
    original_getDocProps = BookInfoManager.getDocProps
    original_extractBookInfo = BookInfoManager.extractBookInfo

    -- Override with hooked versions
    BookInfoManager.getBookInfo = hooked_getBookInfo
    BookInfoManager.getDocProps = hooked_getDocProps
    BookInfoManager.extractBookInfo = hooked_extractBookInfo

    return true
end

-- Uninstall the hook (for cleanup)
function BookInfoManagerHook:uninstall()
    if not original_getBookInfo and not original_getDocProps and not original_extractBookInfo then
        return
    end

    local kamare = self.kamare_instance
    if kamare and kamare.BookInfoManager then
        if original_getBookInfo then
            kamare.BookInfoManager.getBookInfo = original_getBookInfo
        end
        if original_getDocProps then
            kamare.BookInfoManager.getDocProps = original_getDocProps
        end
        if original_extractBookInfo then
            kamare.BookInfoManager.extractBookInfo = original_extractBookInfo
        end
    end

    original_getBookInfo = nil
    original_getDocProps = nil
    original_extractBookInfo = nil
end

return BookInfoManagerHook
