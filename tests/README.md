# Network recovery regression tests

Run from the repository root with LuaJIT:

```sh
luajit tests/network_recovery.lua
```

The suite loads the actual network helper, viewer methods, and client request
builder with simulated KOReader UI, PocketBook APIs, clock, and HTTP callbacks.
It does not need a device, server, credentials, or network access.

It covers already-connected Wi-Fi keepalive, reconnect throttling, resolver
refresh, suspend/resume, metadata retry and page numbering, authorization
failure, callbacks after close, visible-page retry, exhausted prefetch recovery,
HTTP 429, offline gating, cancellation, and both authentication request headers.

These tests validate state transitions, not the device driver or live network.
For device validation, start KOReader with Wi-Fi already enabled, read a remote
chapter, briefly interrupt connectivity, restore it, and check that missing
pages load without reopening the chapter. Also test loss of connectivity when
opening a chapter, closing during retry, and suspend/resume. Distinguish these
controlled checks from long-term observation of an intermittent failure.
