-- TODO prefetch if next in playlist?
-- TODO handle torrent with multiple video files (if webtorrent can print json)
-- - don't close kill webtorrent while still videos unplayed? or in playlist?
-- - store titles/info when starting webtorrent and check stream-open-filename
--   for any item in playlist to see if it matches stored entry

local settings = {
   close_webtorrent = true,
   remove_files = true,
   download_directory = "/tmp/webtorrent",
   webtorrent_flags = ""
}

(require "mp.options").read_options(settings, "webtorrent-hook")

local counter = 0
local open_videos = {}

-- http://lua-users.org/wiki/StringRecipes
local function ends_with(str, ending)
   return ending == "" or str:sub(-#ending) == ending
end

-- https://stackoverflow.com/questions/132397/get-back-the-output-of-os-execute-in-lua
function os.capture(cmd, decolorize, raw)
   if decolorize then
      -- https://github.com/webtorrent/webtorrent-cli/issues/132
      -- TODO webtorrent should have a way to just print json information with
      -- no colors
      -- https://stackoverflow.com/questions/19296667/remove-ansi-color-codes-from-a-text-file-using-bash/30938702#30938702
      cmd = cmd .. " | sed -r 's/\\x1B\\[(([0-9]{1,2})?(;)?([0-9]{1,2})?)?[m,K,H,f,J]//g'"
   end
   local f = assert(io.popen(cmd, 'r'))
   local s = assert(f:read('*a'))
   f:close()
   if raw then return s end
   s = string.gsub(s, '^%s+', '')
   s = string.gsub(s, '%s+$', '')
   -- s = string.gsub(s, '[\n\r]+', ' ')
   return s
end

function play_torrent()
   local url = mp.get_property("stream-open-filename")
   if (url:find("magnet:") == 1 or url:find("peerflix://") == 1
       or url:find("webtorrent://") == 1 or ends_with(url, ".torrent")) then
      if url:find("webtorrent://") == 1 then
         url = url:sub(14)
      end
      if url:find("peerflix://") == 1 then
         url = url:sub(12)
      end

      mp.msg.info("Starting webtorrent")
      -- don't reuse files (useful if ever support queuing)
      counter = counter + 1
      local output_file = settings.download_directory
         .. "/webtorrent-output-" .. counter .. ".log"
      -- --keep-seeding is to prevent webtorrent from quitting once the download
      -- is done
      local webtorrent_command = "webtorrent "
         .. settings.webtorrent_flags
         .. " --out '" .. settings.download_directory .. "' --keep-seeding '"
         .. url .. "' &> " .. output_file .. " & echo $!"
      local pid = os.capture(webtorrent_command)

      mp.msg.info("Waiting for webtorrent server")
      local url_command = "tail -f " .. output_file
         .. " | awk '/Server running at:/ {print $4; exit}'"
      local url = os.capture(url_command, true)
      mp.msg.info("Webtorrent server is up")

      local title_command = "awk '/(Seeding|Downloading): / "
         .. "{gsub(/(Seeding|Downloading): /, \"\"); print; exit}' "
         .. output_file
      local title = os.capture(title_command, true)
      mp.msg.info("Setting media title to: " .. title)
      mp.set_property("force-media-title", title)

      local path = settings.download_directory .. "/" .. title
      open_videos[url] = {title=title,path=path,pid=pid}

      mp.set_property("stream-open-filename", url)
   end
end

function webtorrent_cleanup()
   if settings.close_webtorrent then
      local url = mp.get_property("stream-open-filename")
      mp.msg.info("Closing webtorrent for " .. open_videos[url].title)
      os.execute("kill " .. open_videos[url].pid)
      if settings.remove_files then
         mp.msg.info("Removing media file for " .. open_videos[url].title)
         os.execute("rm '" .. open_videos[url].path .. "'")
      end
      open_videos[url] = {}
   end
end

mp.add_hook("on_load", 50, play_torrent)

mp.add_hook("on_unload", 10, webtorrent_cleanup)
