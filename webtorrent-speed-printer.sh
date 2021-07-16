#!/usr/bin/env bash
out_dir=$1
output_file="$out_dir"/webtorrent-output
printer_pid_file="$out_dir"/printer.pid

tail -f "$output_file" \
	| awk '/Speed:/ { printf ("\r%s%s%s", "\033[1;31m", $0, "\033[0m "); }' \
		  >&2 &
echo -n $! > "$printer_pid_file"
