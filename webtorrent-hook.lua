-- TODO prefetch if next in playlist?
-- TODO handle torrent with multiple video files (if webtorrent can print json)
-- - don't close kill webtorrent while still videos unplayed? or in playlist?
-- - store titles/info when starting webtorrent and check stream-open-filename
--   for any item in playlist to see if it matches stored entry

local settings = {
   close_webtorrent = true,
   remove_files = true,
   download_directory = "/tmp/webtorrent",
   webtorrent_flags = "",
   webtorrent_verbosity = "speed"
}

(require "mp.options").read_options(settings, "webtorrent-hook")

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

function read_file(file)
   local fh = assert(io.open(file, "rb"))
   local contents = fh:read("*all")
   fh:close()
   return contents
end

function play_torrent()
   local url = mp.get_property("stream-open-filename")
   if (url:find("magnet:") == 1 or url:find("peerflix://") == 1
       or url:find("webtorrent://") == 1 or ends_with(url, "torrent")) then
      if url:find("webtorrent://") == 1 then
         url = url:sub(14)
      end
      if url:find("peerflix://") == 1 then
         url = url:sub(12)
      end

      os.execute("mkdir -p " .. settings.download_directory)
      -- don't reuse files (so multiple mpvs works)
      local output_file = settings.download_directory
         .. "/webtorrent-output-" .. mp.get_time() .. ".log"
      -- --keep-seeding is to prevent webtorrent from quitting once the download
      -- is done
      local webtorrent_command = "webtorrent download '"
         .. url .. "' "
         .. settings.webtorrent_flags
         .. " --out '" .. settings.download_directory .. "' --keep-seeding &> " 
         .. output_file .. " & echo $!"
      local pid = os.capture(webtorrent_command)
      mp.msg.info("Waiting for webtorrent server")

      local url_command = "tail -f " .. output_file
         .. " | awk '/Server running at:/ {print $3; exit}' | sed 's#^at:##'"
      local url = os.capture(url_command, true)
      mp.msg.info("Webtorrent server is up")

      local title_command = "awk '/(Seeding|Downloading): / "
         .. "{gsub(/(Seeding|Downloading): /, \"\"); print; exit}' "
         .. output_file
      local title = os.capture(title_command, true)
      mp.msg.verbose("Setting media title to: " .. title)
      mp.set_property("force-media-title", title)

      local path
      if title then
         path = settings.download_directory .. "/" .. title
      end
      open_videos[url] = {title=title,path=path,pid=pid}

      mp.set_property("stream-open-filename", url)

      if settings.webtorrent_verbosity == "speed" then
         local printer_pid
         local printer_pid_file = settings.download_directory
            .. "/webtorrent-printer-" .. mp.get_time() .. ".pid"
         os.execute("tail -f " .. output_file
                       .. " | awk '/Speed:/' ORS='\r' & echo -n $! > "
                       .. printer_pid_file)
         printer_pid = read_file(printer_pid_file)
         mp.register_event("file-loaded",
                           function()
                              os.execute("kill " .. printer_pid)
                           end
         )
      end
   end
end

function webtorrent_cleanup()
   local url = mp.get_property("stream-open-filename")
   if settings.close_webtorrent and open_videos[url] then
      local title = open_videos[url].title
      local path = open_videos[url].path
      local pid = open_videos[url].pid

      if pid then
         mp.msg.verbose("Closing webtorrent for " .. title)
         os.execute("kill " .. pid)
      end

      if settings.remove_files then
         if path then
            mp.msg.verbose("Removing media file for " .. title)
            os.execute("rm -r '" .. path .. "'")
         end
      end

      open_videos[url] = {}
   end
end

mp.add_hook("on_load", 50, play_torrent)

mp.add_hook("on_unload", 10, webtorrent_cleanup)
