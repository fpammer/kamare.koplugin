--[[--
Fully non-blocking HTTP/1.1 client for Kavita page images.

Goal: never block the UI thread on network I/O, on any link. A slow/poor
connection just makes the fetch take more steps -- it never freezes input.

Why this exists (not just using socket.http):
  * `socket.http.request` is `socket.protect`-wrapped, and `socket.protect` is a
    C function in this build. Yielding from a coroutine sink crosses that C
    frame -> "attempt to yield across C-call boundary". And the synchronous
    request obviously blocks. So we bypass socket.http entirely.
  * We drive a raw socket ourselves with `settimeout(0)` (fully non-blocking)
    and `socket.select(..., SELECT_WAIT)` (bounded wait, returns on event or timeout). Every phase -- TCP
    connect, TLS handshake, send, header read, body read -- is a step in a
    self-scheduling UIManager loop. Each `step()` does up to ~quantum_ms of
    select+op iterations, then `scheduleIn(PUMP_RESCHEDULE_S, step)`; between
    steps UIManager processes input and paint. There is no coroutine and no
    yield, so no C-boundary is ever crossed, and no network wait ever blocks.

Supported: HTTPS (TLS via LuaSec, non-blocking handshake), Content-Length,
chunked transfer-encoding (decoded at completion), HTTP redirects (<= 5),
GET and POST (request body sent verbatim when `req_table.body` is a string;
caller sets Content-Type via headers, Content-Length is added automatically).

Driven by: the prefetch chain (background fill) and the render path
(placeholder + repaint-on-arrival), both via _ensurePageReady in the viewer;
also the async progress-POST path in the viewer.
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")
local ssl = require("ssl")
local socketutil = require("socketutil")
local time = require("ui/time")
local url = require("socket.url")

local AsyncFetch = {}

local TLS_PARAMS = {
    protocol = "any",
    options  = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
    verify   = "none",
    mode     = "client",
}

-- Gap between pump invocations. Must be > 0: with scheduleIn(0)/nextTick the
-- task is always "due" so UIManager's `repeat _checkTasks _repaint until not
-- dirty` loop never exits and INPUT (scroll/touch) is starved. A small future
-- delay forces the loop to exit between steps so input is processed.
local PUMP_RESCHEDULE_S = 0.005

-- How long socket.select() waits for readiness before returning. Using 0 (poll)
-- causes a busy-loop at ~200Hz during idle-wait phases (every cycle triggers a
-- UIManager _repaint → massive log spam + CPU waste). A 50ms wait lets the
-- pump block efficiently until data arrives, dropping poll frequency to ~20Hz.
-- Input latency is bounded to this + quantum_ms. Tunable.
local SELECT_WAIT = 0.1

local QUANTUM_MS_DEFAULT = 60
local HEAD_BUFSIZE   = 4096
local BODY_BUFSIZE   = 16384
local MAX_REDIRECTS  = 5

-- NOTE: non-blocking TLS here is driven manually (ssl.wrap + dohandshake +
-- socket.select on the wrapped socket), which is NOT a pattern KOReader uses
-- elsewhere (frontend/socketutil.lua uses the high-level ssl.https). This works
-- on desktop builds but is not yet verified on every e-ink target. All TLS
-- entry points are pcall-guarded so a misbehaving LuaSec build surfaces a clean
-- fetch failure instead of aborting the pump.
-- Wrap a plain socket in TLS. pcall-guarded: returns (ss) or (nil, err).
local function wrap_tls(sock, host)
    local ok, ss, werr = pcall(ssl.wrap, sock, TLS_PARAMS)
    if not ok then return nil, "ssl.wrap threw: " .. tostring(ss) end
    if not ss then return nil, "ssl.wrap: " .. tostring(werr) end
    ss:sni(host)
    ss:settimeout(0)
    return ss
end

--- Parse an absolute URL into target fields.
local function parse_target(u)
    local p = url.parse(u)
    local scheme = p.scheme or "http"
    local host = assert(p.host, "URL missing host")
    local port = p.port or (scheme == "https" and 443 or 80)
    local path = (p.path or "/") .. (p.query and ("?" .. p.query) or "")
    local host_header = host .. ((port == 80 or port == 443) and "" or (":" .. port))
    return { scheme = scheme, host = host, port = port, path = path,
             host_header = host_header, url = u }
end

--- Decode a raw chunked-transfer-encoded body. Returns decoded string or (nil, err).
local function decode_chunked(raw)
    local pos = 1
    local out = {}
    while true do
        local line_end = raw:find("\r\n", pos, true)
        if not line_end then return nil, "chunk: no size line" end
        local size_str = raw:sub(pos, line_end - 1):gsub(";.*$", "")
        local size = tonumber(size_str, 16)
        if not size then return nil, "chunk: bad size '" .. size_str .. "'" end
        pos = line_end + 2
        if size == 0 then
            return table.concat(out) -- ignore trailers
        end
        local data = raw:sub(pos, pos + size - 1)
        if #data < size then return nil, "chunk: truncated data" end
        out[#out + 1] = data
        pos = pos + size
        if raw:sub(pos, pos + 1) ~= "\r\n" then return nil, "chunk: missing CRLF" end
        pos = pos + 2
    end
end

--- Fetch `req_table` ({url, method, headers}) without ever blocking the UI.
--- opts: { quantum_ms, total_timeout }
--- on_done(body_or_nil, code_or_nil, stats) fires once at completion.
---   stats = { bytes, total_ms, handshake_ms, firstbyte_ms, throughput_Bps, err }.
---   On success: (body, 200-ish_code, stats) with stats.err == nil.
---   On failure: (nil, code_or_nil, stats) where code is the HTTP code if
---   headers arrived (else nil) and stats.err carries the reason string.
--- Returns a handle with :cancel() (works in every phase).
function AsyncFetch.fetch(req_table, opts, on_done)
    opts = opts or {}
    local quantum_ms    = opts.quantum_ms or QUANTUM_MS_DEFAULT
    local total_timeout = opts.total_timeout or socketutil.FILE_TOTAL_TIMEOUT
    local t_start       = time.now()

    local method     = req_table.method or "GET"
    local req_headers = req_table.headers or {}
    local cur        = parse_target(req_table.url)

    -- ---- state ----
    local sock                     -- current socket (plain or TLS)
    local phase = "connect"        -- connect | tls | send | head | body | done
    local send_buf, sent_offset = nil, 0
    local head_buf = ""
    local code, headers = nil, {}
    local content_length, body_mode = nil, "close" -- "length" | "chunked" | "close"
    local body_chunks, received = {}, 0
    local body_tail = "" -- last few raw bytes, for chunked terminator detection
    local body_predecoded = false  -- true once chunked fast-path verified the terminator
    local predecoded_body          -- the verified decoded body when body_predecoded is true
    local redirect_count = 0
    local ticks, recv_max_ms = 0, 0
    local first_chunk_ms, handshake_ms = nil, nil
    local cancelled = false
    local result_err = nil

    local function fail(err)
        result_err = err
        phase = "done"
    end

    local function finalize()
        if sock then pcall(function() sock:close() end); sock = nil end
        local total_ms = time.to_ms(time.now() - t_start)
        local body
        if body_predecoded then
            -- Chunked body was already verified+decoded by the fast-path in
            -- do_body(); use it directly and skip the at-end decode below.
            body = predecoded_body
        else
            body = table.concat(body_chunks)
            -- Decode chunked (if applicable) now that we have the full raw body.
            if not result_err and body_mode == "chunked" and code == 200 then
                local decoded, derr = decode_chunked(body)
                if not decoded then
                    result_err = "chunked decode: " .. derr
                else
                    body = decoded
                    received = #body
                end
            end
        end
        local throughput_Bps = (total_ms > 0) and math.floor(received * 1000 / total_ms) or 0
        -- Observed network stats for callers (adaptive prefetch). On a
        -- transport failure, code is the HTTP code if headers were received
        -- (else nil) and err carries the reason string; on a 2xx success err
        -- is nil. bytes/total_ms always carry partial-progress info.
        local stats = {
            bytes = received,
            total_ms = total_ms,
            handshake_ms = handshake_ms,
            firstbyte_ms = first_chunk_ms,
            throughput_Bps = throughput_Bps,
            err = result_err and tostring(result_err) or nil,
        }
        if result_err then
            logger.dbg(string.format("[kamare:asyncfetch] FAIL err=%s bytes=%d/%s ticks=%d total=%dms",
                tostring(result_err), received, tostring(content_length), ticks, total_ms))
            if on_done then on_done(nil, code, stats) end
        else
            logger.dbg(string.format(
                "[kamare:asyncfetch] done code=%s bytes=%d handshake=%dms firstbyte=%dms ticks=%d recv_max=%dms total=%dms %.2f MB/s",
                tostring(code), received, handshake_ms or -1, first_chunk_ms or -1,
                ticks, recv_max_ms, total_ms, throughput_Bps / (1024 * 1024)))
            if on_done then on_done(body, code, stats) end
        end
    end

    local function build_request_bytes()
        local r = string.format("%s %s HTTP/1.1\r\nHost: %s\r\n", method, cur.path, cur.host_header)
        local body_bytes = req_table.body
        if type(body_bytes) == "string" and #body_bytes > 0 and not req_headers["Content-Length"] then
            req_headers["Content-Length"] = tostring(#body_bytes)
        end
        for k, v in pairs(req_headers) do
            r = r .. k .. ": " .. tostring(v) .. "\r\n"
        end
        -- Terminate headers; append body bytes (if any) so do_send ships them
        -- in the same send_buf. Body-less requests behave exactly as before.
        if body_bytes and #body_bytes > 0 then
            return r .. "Connection: close\r\n\r\n" .. body_bytes
        end
        return r .. "Connection: close\r\n\r\n"
    end

    local function note_handshake_done()
        if handshake_ms == nil then handshake_ms = time.to_ms(time.now() - t_start) end
    end

    -- Begin (re)connecting to `cur`. Sets phase to connect/tls/send or fails.
    local function start_connect()
        if sock then pcall(function() sock:close() end); sock = nil end
        sock = socket.tcp()
        if not sock then
            fail("socket.tcp() failed")
            return
        end
        sock:settimeout(0) -- fully non-blocking from here on
        local ok, err = sock:connect(cur.host, cur.port)
        if ok then
            -- immediate connect (loopback / fast path)
            if cur.scheme == "https" then
                local ss, werr = wrap_tls(sock, cur.host)
                if not ss then fail(werr); return end
                sock = ss; phase = "tls"
            else
                note_handshake_done()
                phase = "send"; send_buf = build_request_bytes(); sent_offset = 0
            end
        elseif err == "Operation already in progress" or err == "timeout" then
            phase = "connect"
        else
            fail("connect: " .. tostring(err))
        end
    end

    -- returns true if the phase advanced (loop again), false if it must wait
    -- (reschedule). Sets phase="done" / result_err on completion/failure.
    local function do_connect()
        local _, w, serr = socket.select(nil, {sock}, SELECT_WAIT)
        if serr and serr ~= "timeout" then fail("select(connect): " .. serr); return true end
        if not w or not w[1] then return false end -- not writable yet
        -- Read SO_ERROR to detect a failed non-blocking connect. getoption is
        -- pcall-guarded: some embedded LuaSocket builds lack the "error" option;
        -- if we can't query it, assume success and let the next phase fail loudly
        -- rather than swallowing the error silently.
        local gok, cerr = pcall(function() return sock:getoption("error") end)
        if gok and cerr and cerr ~= 0 then
            fail("connect failed (errno " .. tostring(cerr) .. ")"); return true
        end
        if cur.scheme == "https" then
            local ss, werr = wrap_tls(sock, cur.host)
            if not ss then fail(werr); return true end
            sock = ss; phase = "tls"
        else
            note_handshake_done()
            phase = "send"; send_buf = build_request_bytes(); sent_offset = 0
        end
        return true
    end

    local function do_tls()
        -- pcall-guard: a misbehaving LuaSec build may throw instead of returning
        -- a wantread/wantwrite string; surface that as a clean failure.
        local hok, ok, herr = pcall(sock.dohandshake, sock)
        if not hok then fail("dohandshake threw: " .. tostring(ok)); return true end
        if ok then
            note_handshake_done()
            phase = "send"; send_buf = build_request_bytes(); sent_offset = 0
            return true
        end
        if herr == "wantread" then
            local r, _, serr = socket.select({sock}, nil, SELECT_WAIT)
            if serr and serr ~= "timeout" then fail("select(tls r): " .. serr); return true end
            if not r or not r[1] then return false end
            return true -- retry dohandshake
        elseif herr == "wantwrite" then
            local _, w, serr = socket.select(nil, {sock}, SELECT_WAIT)
            if serr and serr ~= "timeout" then fail("select(tls w): " .. serr); return true end
            if not w or not w[1] then return false end
            return true
        else
            fail("dohandshake: " .. tostring(herr)); return true
        end
    end

    local function do_send()
        local tail, serr = sock:send(send_buf, sent_offset + 1)
        if tail then sent_offset = tail end
        if serr == "closed" then fail("send closed"); return true end
        if serr and serr ~= "timeout" then fail("send: " .. tostring(serr)); return true end
        if serr == "timeout" then
            local _, w, selt = socket.select(nil, {sock}, SELECT_WAIT)
            if selt and selt ~= "timeout" then fail("select(send): " .. selt); return true end
            if not w or not w[1] then return false end
            return true
        end
        -- serr == nil: full success for the requested range
        if sent_offset >= #send_buf then
            phase = "head"; head_buf = ""
        end
        return true
    end

    local function do_head()
        local chunk, rerr, partial = sock:receive(HEAD_BUFSIZE)
        local got = chunk or partial
        if got and #got > 0 then
            head_buf = head_buf .. got
        end
        local head_end = head_buf:find("\r\n\r\n", 1, true)
        if head_end then
            -- parse status line + headers (everything up to head_end+2)
            local header_block = head_buf:sub(1, head_end + 2)
            local first_eol = header_block:find("\r\n", 1, true)
            local status_line = first_eol and header_block:sub(1, first_eol - 1) or ""
            local c = status_line:match("HTTP/%d*%.%d* (%d%d%d)")
            if not c then fail("unparsed status line: " .. tostring(status_line)); return true end
            code = tonumber(c)
            local hs = {}
            for line in header_block:sub(first_eol + 2):gmatch("([^\r\n]+)") do
                local k, v = line:match("^([^:]+):%s*(.*)$")
                if k then hs[k:lower()] = v end
            end
            headers = hs
            -- carry any body bytes that arrived with the head
            local body_start = head_buf:sub(head_end + 4)
            if #body_start > 0 then
                body_chunks[#body_chunks + 1] = body_start
                received = #body_start
                if first_chunk_ms == nil then first_chunk_ms = time.to_ms(time.now() - t_start) end
            end
            -- redirect handling
            if code >= 300 and code < 400 and headers["location"] then
                redirect_count = redirect_count + 1
                if redirect_count > MAX_REDIRECTS then fail("too many redirects"); return true end
                local loc = headers["location"]
                local new_url
                if loc:match("^https?://") then
                    new_url = loc
                elseif loc:sub(1, 1) == "/" then
                    new_url = cur.scheme .. "://" .. cur.host_header .. loc
                else
                    local dir = cur.path:match("^(.*)/") or "/"
                    new_url = cur.scheme .. "://" .. cur.host_header .. dir .. "/" .. loc
                end
                logger.dbg("[kamare:asyncfetch] redirect " .. tostring(code) .. " -> " .. new_url)
                cur = parse_target(new_url)
                head_buf = ""; body_chunks = {}; received = 0; code = nil; headers = {}
                start_connect()
                return true
            end
            -- determine body mode
            content_length = headers["content-length"] and tonumber(headers["content-length"]) or nil
            local te = headers["transfer-encoding"]
            if te and te:lower():find("chunked") then
                body_mode = "chunked"
            elseif content_length then
                body_mode = "length"
            else
                body_mode = "close"
            end
            logger.dbg(string.format(
                "[kamare:asyncfetch] response code=%s content-length=%s mode=%s",
                tostring(code), tostring(content_length), body_mode))
            -- short-circuit: body already fully delivered with the head + closed
            if body_mode == "length" and received >= content_length then
                phase = "done"; return true
            end
            if body_mode == "close" and rerr == "closed" then
                phase = "done"; return true
            end
            phase = "body"
            return true
        end
        -- head not complete yet
        if rerr == "closed" then fail("closed during head"); return true end
        if (not got) or rerr == "timeout" or rerr == "wantread" then
            local r, _, serr = socket.select({sock}, nil, SELECT_WAIT)
            if serr and serr ~= "timeout" then fail("select(head): " .. serr); return true end
            if not r or not r[1] then return false end
        end
        return true
    end

    local function do_body()
        local want
        if body_mode == "length" then
            want = math.min(BODY_BUFSIZE, content_length - received)
        else
            want = BODY_BUFSIZE
        end
        local t_recv = time.now()
        local chunk, rerr, partial = sock:receive(want)
        local dt = time.to_ms(time.now() - t_recv)
        if dt > recv_max_ms then recv_max_ms = dt end
        local got = chunk or partial
        if got and #got > 0 then
            if first_chunk_ms == nil then first_chunk_ms = time.to_ms(time.now() - t_start) end
            body_chunks[#body_chunks + 1] = got
            received = received + #got
            body_tail = (body_tail .. got):sub(-8)
            -- Chunked fast-path: the body *may* have ended with the zero-size
            -- chunk marker "0\r\n\r\n" (no trailers). Verify by actually decoding
            -- before committing -- image data could in principle contain those 5
            -- bytes mid-stream and trigger a false positive. On a successful
            -- decode we're truly done; on failure it was a false positive, so
            -- keep reading and let Connection: close finish the body.
            if body_mode == "chunked" and body_tail:sub(-5) == "0\r\n\r\n" then
                local decoded = decode_chunked(table.concat(body_chunks))
                if decoded then
                    predecoded_body = decoded
                    body_predecoded = true
                    received = #decoded
                    phase = "done"; return true
                end
            end
        end
        if body_mode == "length" and received >= content_length then
            phase = "done"; return true
        end
        if rerr == "closed" then
            if body_mode == "length" then
                if received == content_length then phase = "done"
                else fail("body truncated: " .. received .. "/" .. content_length) end
            else
                phase = "done" -- chunked/close: decode-at-end (chunked) or as-is (close)
            end
            return true
        end
        if rerr and rerr ~= "timeout" and rerr ~= "wantread" then
            fail("body recv: " .. tostring(rerr)); return true
        end
        if (not got) or rerr == "timeout" or rerr == "wantread" then
            local r, _, serr = socket.select({sock}, nil, SELECT_WAIT)
            if serr and serr ~= "timeout" then fail("select(body): " .. serr); return true end
            if not r or not r[1] then return false end
        end
        return true
    end

    local function step()
        if cancelled then result_err = "cancelled"; phase = "done" end
        if phase == "done" then finalize(); return end
        -- total timeout backstop
        if time.to_ms(time.now() - t_start) > total_timeout * 1000 then
            fail("total timeout"); finalize(); return
        end
        local q_start = time.now()
        while true do
            ticks = ticks + 1
            local advanced
            if     phase == "connect" then advanced = do_connect()
            elseif phase == "tls"     then advanced = do_tls()
            elseif phase == "send"    then advanced = do_send()
            elseif phase == "head"    then advanced = do_head()
            elseif phase == "body"    then advanced = do_body()
            else advanced = true end
            if phase == "done" or result_err then finalize(); return end
            if not advanced then break end          -- waiting for readiness; reschedule
            if time.to_ms(time.now() - q_start) >= quantum_ms then break end
        end
        if not cancelled and phase ~= "done" and not result_err then
            UIManager:scheduleIn(PUMP_RESCHEDULE_S, step)
        end
    end

    -- Kick off. start_connect sets the initial phase; step drives from there.
    start_connect()
    if phase == "done" or result_err then
        finalize()
    else
        UIManager:scheduleIn(PUMP_RESCHEDULE_S, step)
    end

    return {
        cancel = function()
            cancelled = true
            if sock then pcall(function() sock:close() end); sock = nil end
        end,
    }
end

return AsyncFetch
