#!/bin/zsh
set -e

TESTPNG="${TMPDIR:-/tmp}/kgd-test-$$.png"
trap "rm -f $TESTPNG" EXIT

# Generate test image with random named color each run
/usr/bin/env python3 -c "
import struct, zlib, random, sys
def png(w,h,r,g,b):
    raw=b''
    for y in range(h):
        raw+=b'\x00'+bytes([r,g,b,255])*w
    c=zlib.compress(raw)
    def chunk(t,d):return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',c)+chunk(b'IEND',b'')
colors={'red':(255,0,0),'green':(0,255,0),'blue':(0,0,255),'yellow':(255,255,0),'magenta':(255,0,255),'cyan':(0,255,255),'orange':(255,128,0),'purple':(128,0,255),'white':(255,255,255),'pink':(255,105,180)}
name=random.choice(list(colors))
r,g,b=colors[name]
open(sys.argv[1],'wb').write(png(100,100,r,g,b))
print(f'{name}')
" "$TESTPNG"

pkill -f "kgd serve" 2>/dev/null || true
sleep 0.5
./kgd serve --log-level debug --log-stderr &
DAEMON_PID=$!
sleep 1
if ! kill -0 $DAEMON_PID 2>/dev/null; then
    echo "ERROR: daemon died. Check ~/.local/state/kgd/kgd.log"
    tail -20 ~/.local/state/kgd/kgd.log
    exit 1
fi
echo "daemon running pid=$DAEMON_PID"
handle=$(./kgd upload "$TESTPNG")
echo "handle=$handle"
./kgd place "$handle" --row 5 --col 5
echo "placed"
sleep 1
./kgd list
