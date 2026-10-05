package.path = 'src/?.lua;' .. package.path
local queue, now, connected, pings, reconnects, resets = {}, 0, true, 0, 0, 0
local reconnect_ok = true
local UI = {}
function UI:scheduleIn(delay, fn) queue[#queue+1] = {at=now+delay, fn=fn} end
function UI:unschedule(fn) for i=#queue,1,-1 do if queue[i].fn==fn then table.remove(queue,i) end end end
function UI:setDirty() end
local function step()
    assert(#queue>0, 'no scheduled work')
    table.sort(queue,function(a,b)return a.at<b.at end)
    local task=table.remove(queue,1); now=task.at; task.fn()
end
local function reset() queue={};now=0;connected=true;pings=0;reconnects=0;resets=0;reconnect_ok=true end
local NetworkMgr = {isWifiOn=function() return connected end, isConnected=function() return connected end,
 turnOnWifi=function() reconnects=reconnects+1;connected=reconnect_ok end}
local Device={isPocketBook=function()return true end, hasBattery=function()return true end,
 screen={scaleBySize=function(_,n)return n end}}
package.loaded['device']=Device
package.loaded['ui/network/manager']=NetworkMgr
package.loaded['ui/uimanager']=UI
package.loaded['ui/time']={now=function()return now end,to_s=function(n)return n end,to_ms=function(n)return n*1000 end}
package.loaded['ffi/inkview']={NetMgrPing=function()pings=pings+1 end}
package.loaded['ffi']={C={res_init=function()resets=resets+1 end}}
package.loaded['logger']={info=function()end,warn=function()end,dbg=function()end}
local Network=require('kamarenetwork')
local function test(name,fn)reset();fn();print('PASS '..name)end

test('already connected starts PocketBook keepalive; close cancels it',function()
 local n=Network.new();assert(pings==1);step();assert(pings==2);n:close();assert(#queue==0)
end)
test('reconnects are shared and throttled, then recover',function()
 local n=Network.new();connected=false;reconnect_ok=false
 assert(not n:ready());assert(not n:ready());assert(reconnects==1)
 now=31;reconnect_ok=true;assert(n:ready());assert(reconnects==2);n:close()
end)
test('DNS resolver refresh throttled and suspend prevents reconnect',function()
 local n=Network.new();n:onFailure('connect: temporary failure in name resolution');n:onFailure('temporary failure in name resolution');assert(resets==1)
 n:suspend();connected=false;assert(not n:ready());assert(reconnects==0);assert(#queue==0)
 n:resume();assert(n:ready());assert(reconnects==1);n:close();assert(not n:ready())
end)

-- Load the real viewer with platform/UI dependencies replaced, without init.
local Class={}
function Class:extend(t)return setmetatable(t or {},{__index=self})end
function Class:new(t)return self:extend(t)end
local names={'kamarefooter','ui/widget/container/widgetcontainer','ui/widget/container/centercontainer','ui/widget/container/framecontainer','ui/widget/verticalgroup','ffi/blitbuffer','ui/widget/frontlightwidget','document/doccache','ui/widget/configdialog','document/canvascontext','kamareoptions','frontend/configurable','ui/widget/container/inputcontainer','ui/widget/titlebar','ui/geometry','virtualimagedocument','virtualpagecanvas','optmath','ui/widget/buttondialog','virtualimagedocumentcache','ui/widget/infomessage','kamareutils'}
for _,name in ipairs(names)do package.loaded[name]=Class end
package.loaded['ffi/sha2']={md5=function()return ''end}
package.loaded['ffi/util']={template=function(s)return s end}
package.loaded['gettext']=function(s)return s end
local decoded
package.loaded['rapidjson']={decode=function() if decoded=='invalid' then error('invalid JSON') end return decoded end}
local client={buildImageRequestTable=function()return {url='https://example/image'}end,
 buildDimensionsRequestTable=function()return {url='https://example/dims'}end}
package.loaded['kavitaclient']=client
local fetch_impl
package.loaded['kamareasyncfetch']={fetch=function(...)return fetch_impl(...)end}
local Viewer=require('kamareimageviewer')
local function viewer()
 local doc={_dims_cache={},_pages=2}
 function doc:_hasCompleteDimensions()return self.complete or false end
 function doc:preloadDimensions(dims)self.dims=dims;self.complete=#dims==2 end
 function doc:_buildDualPageLayout()self.layout=true end
 function doc:isRawBodyReady()return false end
 function doc:injectRawBody(_,body)self.body=body end
 function doc:getNativePageDimensions()return {w=100,h=200}end
 function doc:prefetchPage()return 1 end
 function doc:clearCache()self.cleared=true end
 function doc:close()end
 local v=setmetatable({virtual_document=doc,metadata={chapterId=1},_prefetch_gen=0,
 _page_fetch_failed={},_page_fetch_inflight={},_page_fetch_retries={},_pending_repaint_pages={},_fetch_handles={},
 canvas={_renderDimsFor=function()return 100,200 end,dimen={},setDocument=function()end}}, {__index=Viewer})
 v.update=function(self)self.updated=true end
 v.getCurrentZoom=function()return 1 end
 v._fetchTimeoutSec=function()return 15 end
 v._recordNetSample=function()end
 v._currentVisiblePages=function()return {} end
 return v,doc
end
local function response(body,code,err)
 return function(req,opts,cb)cb(body,code,{err=err});return {cancel=function()end}end
end

test('metadata DNS failure then recovery normalizes page numbers and updates layout',function()
 local v,d=viewer();fetch_impl=response(nil,nil,'temporary failure in name resolution')
 v:_recoverDimensions();assert(#queue==1 and not d.complete)
 decoded={{pageNumber=0,width=100,height=200},{pageNumber=1,width=200,height=100}}
 fetch_impl=response('{}',200);step()
 assert(d.complete and d.dims[1].pageNumber==1 and d.dims[2].pageNumber==2 and d.layout and v.updated)
 assert(not v._dimensions_pending and #queue==0)
end)
test('invalid metadata retries; permanent authorization errors stop',function()
 local v=viewer();decoded='invalid';fetch_impl=response('{}',200);v:_recoverDimensions();assert(#queue==1)
 fetch_impl=response(nil,401);step();assert(#queue==0 and not v._dimensions_pending)
end)
test('metadata callback after close cannot change a new document',function()
 local v,d=viewer();local callback;local cancelled=false
 fetch_impl=function(req,opts,cb)callback=cb;return {cancel=function()cancelled=true end}end
 v:_recoverDimensions();v:onCloseWidget();assert(cancelled)
 decoded={{pageNumber=0,width=1,height=1},{pageNumber=1,width=1,height=1}}
 callback('{}',200,{});assert(not d.complete and not v.updated)
end)
test('visible page retries DNS failure and succeeds without reopening',function()
 local v,d=viewer();local done=0;fetch_impl=response(nil,nil,'temporary failure in name resolution')
 v:_ensurePageReady(1,0,function()done=done+1 end,true);assert(done==0 and #queue==1)
 fetch_impl=response('image',200);step();assert(done==1 and d.body=='image' and not v._page_fetch_inflight[1])
end)
test('exhausted prefetch is retried when page becomes visible',function()
 local v,d=viewer();fetch_impl=response(nil,nil,'timeout')
 v:_ensurePageReady(1,0);for i=1,3 do step()end
 assert(v._page_fetch_failed[1]=='transient')
 fetch_impl=response('image',200);v:_ensurePageReady(1,0,nil,true);assert(d.body=='image' and not v._page_fetch_failed[1])
end)
test('permanent image errors do not spin; 429 is retried',function()
 local v=viewer();fetch_impl=response(nil,403);v:_ensurePageReady(1,0,nil,true)
 assert(v._page_fetch_failed[1]=='permanent' and #queue==0)
 v:_ensurePageReady(1,0,nil,true);assert(#queue==0)
 fetch_impl=response(nil,429);v:_ensurePageReady(2,0,nil,true);assert(#queue==1)
end)
test('offline request waits for network before downloading',function()
 local v,d=viewer();local ready=false;local calls=0
 v._network={ready=function()return ready end,onFailure=function()end}
 fetch_impl=function(...)calls=calls+1;return response('image',200)(...)end
 v:_ensurePageReady(1,0,nil,true);assert(calls==0 and #queue==1)
 ready=true;step();assert(calls==1 and d.body=='image')
end)
test('close cancels scheduled metadata retry and page retry cannot start fetch',function()
 local v=viewer();fetch_impl=response(nil,nil,'timeout')
 v:_recoverDimensions();v:_ensurePageReady(1,0,nil,true);v:onCloseWidget()
 fetch_impl=function()error('fetch after close')end
 while #queue>0 do step()end
end)

test('real client builds authenticated metadata request and rejects missing credentials',function()
 for _,name in ipairs({'version','socket.http','ltn12','socket','socketutil'})do package.loaded[name]={}end
 package.loaded['cache']=Class
 package.loaded['socket.url']={escape=function(s)return tostring(s)end}
 local actual=assert(loadfile('src/kavitaclient.lua'))()
 actual.base_url='https://example.invalid/'
 actual._generateClientInfoHeader=function()return 'test' end
 actual.auth_method='apiKey';actual.api_key='fixture-only'
 local req=assert(actual:buildDimensionsRequestTable(42))
 assert(req.url:find('/api/Reader/file%-dimensions?') and req.url:find('chapterId=42',1,true))
 assert(req.headers['x-api-key']=='fixture-only' and req.method=='GET')
 actual.api_key=nil;assert(actual:buildDimensionsRequestTable(42)==nil)
 actual.auth_method='bearer';actual.bearer='fixture-bearer'
 assert(actual:buildDimensionsRequestTable(42).headers.Authorization=='Bearer fixture-bearer')
end)
print('All recovery tests passed')
