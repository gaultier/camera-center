#!/usr/bin/env bash
set -ex
set -o pipefail

rpicam-vid -t 0 --inline  --width 1920 --height 1080 -o - --hdr -n   --bitrate 1000000 --post-process-file=motion_detect.json --lores-width 128 --lores-height 128  2> >(./client $1 $2 ) | ffmpeg -re -i /dev/stdin -c copy -f mpegts  'udp://239.0.0.1:12345?ttl=13&pkt_size=1316'  
