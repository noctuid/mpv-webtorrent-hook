-- TODO start webtorrent instance immediately when pasting into playlist instead
-- of waiting for load?
-- TODO what happens with --prefetch-playlist?

local settings = {
   close_webtorrent = true,
   remove_files = true,
   download_directory = "/tmp/webtorrent-hook",
   webtorrent_flags = [[]],
   show_speed = true,
   remember_last_played = true,
   remember_directory = "/tmp/webtorrent-hook-last-played"
}

(require "mp.options").read_options(settings, "webtorrent-hook")

local utils = require "mp.utils";

local webtorrent_instances = {}
local webtorrent_files = {}
local script_dir = mp.get_script_directory()
local printer_pid = nil

-- * Helpers
-- http://lua-users.org/wiki/StringRecipes
function ends_with(str, ending)
   return ending == "" or str:sub(-#ending) == ending
end

function read_file(file)
   local fh = assert(io.open(file, "rb"))
   local contents = fh:read("*all")
   fh:close()
   return contents
end

function write_file(file, text)
   local fh = io.open(file, "w")
   fh:write(text)
   fh:close()
end

function is_handled_url(url, load_failed)
   if load_failed then
      -- info hash
      return (load_failed and string.match(url, "%w+"))
   else
      return (url:find("magnet:") == 1 or url:find("peerflix://") == 1
                 or url:find("webtorrent://") == 1 or ends_with(url, "torrent"))
   end
end

function load_file_after_current(url, option_table, num_entries)
   mp.command_native({
         "loadfile", url, "append", option_table
   })
   local index = mp.get_property("playlist-pos")
   mp.command_native({
         "playlist-move",
         mp.get_property("playlist-count") - 1,
         index + 1 + num_entries
   })
end

-- * Store Last Played Files
function file_info_hash(filename)
   return webtorrent_files[filename]
end

function get_remember_file_path(info_hash)
   return utils.join_path(settings.remember_directory, info_hash)
end

function maybe_store_last_played_torrent_file(_)
   if settings.remember_last_played then
      mp.commandv("run", "mkdir", "-p", settings.remember_directory)
      local filename = mp.get_property("media-title")
      local info_hash = file_info_hash(filename)
      if info_hash ~= nil then
         local remember_file = get_remember_file_path(info_hash)
         write_file(remember_file, filename)
      end
   end
end

mp.register_event("file-loaded", maybe_store_last_played_torrent_file)

function get_last_played_filename_for_torrent(info_hash)
   local remember_file = get_remember_file_path(info_hash)
   if utils.file_info(remember_file) then
      return read_file(remember_file)
   end
end

-- * Play Torrents
function load_webtorrent_files(info_hash, webtorrent_info)
   local first = true
   local found_last_played = false
   local last_played_filename = ""
   if settings.remember_last_played then
      last_played_filename = get_last_played_filename_for_torrent(info_hash)
   end
   local should_remember = settings.remember_last_played
      and last_played_filename
   local file_index = 0
   local file_play_index = 0
   for _, file in pairs(webtorrent_info["files"]) do
      local title = file["title"]
      webtorrent_files[title] = info_hash
      local option_table = {}
      -- TODO is it actually necessary to set force-media-title for sub
      -- plugins? it seems to be correctly set by default for what I've
      -- tried
      option_table["force-media-title"] = title
      local url = file["url"]
      if first then
         load_file_after_current(url, option_table, 0)
         mp.command_native({"playlist-remove", mp.get_property("playlist-pos")})
      else
         load_file_after_current(url, option_table,
                                 file_index - (file_play_index + 1))
         if should_remember and not found_last_played then
            file_play_index = file_play_index + 1
            mp.set_property("playlist-pos", mp.get_property("playlist-pos") + 1)
            if title == last_played_filename then
               found_last_played = true
            end
         end
      end
      file_index = file_index + 1
      first = false
   end
end

function maybe_kill_printer()
   if printer_pid then
      mp.commandv("run", "kill", printer_pid)
      printer_pid = nil
   end
end

mp.register_event("file-loaded", maybe_kill_printer)

function start_speed_printer(out_dir)
      if utils.file_info(utils.join_path(out_dir, "webtorrent-output")) then
      local speed_printer_path =
         utils.join_path(script_dir, "webtorrent-speed-printer.sh")
      os.execute(speed_printer_path .. ' "' .. out_dir .. '"')
      printer_pid = read_file(utils.join_path(out_dir, "printer.pid"))
   end
end

function start_webtorrent(url, torrent_info)
   local base_dir = mp.command_native({
         "expand-path", settings.download_directory
   })
   local info_hash = torrent_info["infoHash"]
   local out_dir = utils.join_path(base_dir, info_hash)

   local wrapper_path =
      utils.join_path(script_dir, "webtorrent-wrap.sh")
   local webtorrent_args = {wrapper_path, out_dir, url}
   local flags = utils.parse_json(settings.webtorrent_flags)
   if flags ~= nil then
      for _, flag in pairs(flags) do
         table.insert(webtorrent_args, flag)
      end
   end
   mp.msg.info("Waiting for webtorrent server")
   local webtorrent_result = mp.command_native({
         name = "subprocess",
         playback_only = false,
         capture_stdout = true,
         args = webtorrent_args
   })
   if webtorrent_result.status == 0 then
      mp.msg.info("Webtorrent server is up")
      local webtorrent_info = utils.parse_json(webtorrent_result.stdout)
      local pid = webtorrent_info["pid"]
      mp.msg.debug(webtorrent_info)
      local name = "Unknown name"
      if torrent_info["name"] ~= nil then
         name = torrent_info["name"]
      end
      table.insert(webtorrent_instances,
                   {download_dir=out_dir,pid=pid,name=name})

      if settings.show_speed then
         start_speed_printer(out_dir)
      end

      load_webtorrent_files(info_hash, webtorrent_info)
   else
      mp.msg.info("Failed to start webtorrent")
   end
end

-- check if the url is a torrent and play it if it is
function maybe_play_torrent(load_failed)
   local url = mp.get_property("stream-open-filename")
   if is_handled_url(url, load_failed) then
      if url:find("webtorrent://") == 1 then
         url = url:sub(14)
      end
      if url:find("peerflix://") == 1 then
         url = url:sub(12)
      end

      local torrent_info_command = mp.command_native({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            args = {"webtorrent", "info", url},
      })
      if torrent_info_command.status == 0 then
         local torrent_info = utils.parse_json(torrent_info_command.stdout)
         local info_hash = torrent_info["infoHash"]
         if info_hash ~= nil then
            start_webtorrent(url, torrent_info)
         end
      end
   end
end

function check_if_torrent_on_load()
   maybe_play_torrent(false)
end

function check_if_torrent_on_load_fail()
   maybe_play_torrent(true)
end

function webtorrent_cleanup()
   if settings.close_webtorrent then
      for _, instance in pairs(webtorrent_instances) do
         mp.msg.verbose("Killing WebTorrent pid " .. instance.pid)
         mp.commandv("run", "kill", instance.pid)
         if settings.remove_files then
            mp.msg.verbose("Removing files for torrent " .. instance.name)
            mp.commandv("run", "rm", "-r", instance.download_dir)
         end
      end
   end
end

mp.add_hook("on_load", 50, check_if_torrent_on_load)
mp.add_hook("on_load_fail", 50, check_if_torrent_on_load_fail)

mp.register_event("shutdown", webtorrent_cleanup)
