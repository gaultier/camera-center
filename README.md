```sh
# Client
cd client
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe
rsync ./zig-out/bin/client <pi address>:~
rsync -v start.sh <pi address>:~
rsync -v camera.service <pi address>:~/.config/systemd/user/camera.service
# On pi:
rpicam-vid -t 0 --inline  --width 1920 --height 1080 --codec libav --libav-format=mpegts  -o  udp://<server address>:12345 --hdr -n   --bitrate 1000000 --post-process-file=motion_detect.json --lores-width 128 --lores-height 128  2>&1 | ./client <server address> 12345

# Server
cd server
zig build -Doptimize=ReleaseSafe
./server/zig-out/bin/server
```
