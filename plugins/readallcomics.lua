#!/usr/bin/env lua
-- ZigZag Comic Plugin: readallcomics.com
-- Outputs JSON to stdout with comic page URLs, title, and nav links.
local url = arg[1]
if not url then print('{"error":"No URL"}'); os.exit(1) end
if not url:find("readallcomics%.com") and not url:find("readallcomics%.net") then os.exit(1) end
local cmd = string.format("curl -sL -H 'User-Agent: Mozilla/5.0' --max-time 15 '%s'", url)
local pipe = io.popen(cmd, "r")
if not pipe then print('{"error":"curl failed"}'); os.exit(1) end
local html = pipe:read("*a"); pipe:close()
if not html or #html < 100 then print('{"error":"Empty"}'); os.exit(1) end
local title = (html:match("<title>(.-)</title>") or ""):gsub('"', '\\"')
local pages = {}
for u in html:gmatch('src="(https?://[^"]+)"') do
  if (u:find("bp%.blogspot%.com") or u:find("blogger%.googleusercontent")) and #u > 30 then
    pages[#pages+1] = u; if #pages >= 128 then break end
  end
end
local nxt, prv = "", ""
for href, text in html:gmatch('<a[^>]+href="(https?://[^"]+)"[^>]*>(.-)</a>') do
  if text:find("Next") and nxt == "" then nxt = href
  elseif text:find("Prev") and prv == "" then prv = href end
end
local jp = {}
for _, p in ipairs(pages) do jp[#jp+1] = '"'..p:gsub('"','\\"')..'"' end
print(string.format('{"title":"%s","pages":[%s],"next_url":"%s","prev_url":"%s"}',
  title, table.concat(jp,","), nxt, prv))
