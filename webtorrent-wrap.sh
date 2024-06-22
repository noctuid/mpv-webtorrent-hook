#!/usr/bin/env bash
out_dir=$1
shift
mkdir -p "$out_dir"

# using file over pipe so multiple processes can read from it and because >(tee
# "$pipe" "$second-pipe-or file") ends up blocking mpv
webtorrent_output_file="$out_dir"/webtorrent-output
nohup webtorrent download "$@" --out "$out_dir" --keep-seeding \
	&> "$webtorrent_output_file" &
pid=$!

cleanup() {
	if (( $? == 1 )); then
		# kill webtorrent if exit with error
		kill $pid
	fi
}
# shellcheck disable=SC2064
trap cleanup EXIT

url=$(tail -f "$webtorrent_output_file" \
		  | awk '/Server running at: ?/ {gsub(/Server running at: ?/, ""); print $1; exit}')

base_url=$(echo "$url" | grep --extended-regexp --only-matching \
							  'http://localhost:[0-9]+')
webtorrent_hash=$(echo "$url" | grep --extended-regexp --only-matching \
							  'webtorrent/[0-9a-f]+')

# Get json of files
webtorrent_results=$(xidel --silent --extract "//a/@href" "$base_url/$webtorrent_hash" |
  jq --null-input --raw-input "
{
    pid: $pid,
    files: [inputs |  select(length>0)] | map({title: . | sub(\"/$webtorrent_hash/\"; \"\"), url: (\"$base_url\" + .)})
}
")

# Uncomment for debugging info
# echo "$webtorrent_results" > ~/webtorrent-wrap.log
# echo "URL             - $url" >> ~/webtorrent-wrap.log
# echo "WEBTORRENT_HASH - $webtorrent_hash" >> ~/webtorrent-wrap.log
# echo "BASE_URL        - $base_url" >> ~/webtorrent-wrap.log

# Print results
echo "$webtorrent_results"
