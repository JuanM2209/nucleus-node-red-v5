#!/bin/sh
# Regression gate for a freshly built image. Run on the build machine (Docker
# with QEMU arm/v7) BEFORE publishing a release:
#   sh tools/verify-image.sh nucleus/node-red:5.0.6-tyrion3-armv7
#
# Every check here corresponds to a real crash we hit on the device. A require()
# test is NOT enough for any of them - the failures only appear on use.
set -eu
IMAGE="${1:?image tag required}"
export MSYS_NO_PATHCONV=1
run()  { docker run --rm --platform linux/arm/v7 --entrypoint sh "$IMAGE" -c "$1"; }
runr() { docker run --rm --platform linux/arm/v7 --user 0 --entrypoint sh "$IMAGE" -c "$1"; }  # root: needed to apk add test tools

echo "== 1. classic-level must open/put/get/close from build/Release (glibc prebuild segfaults on musl)"
run 'node -e "
const {ClassicLevel}=require(\"classic-level\");
const p=require(\"node-gyp-build\").path(\"/usr/src/node-red/node_modules/classic-level\");
if(!/build\/Release/.test(p)){console.error(\"WRONG BINARY: \"+p);process.exit(2)}
const db=new ClassicLevel(\"/tmp/v\");
db.open().then(()=>db.put(\"k\",\"v\")).then(()=>db.get(\"k\")).then(v=>{if(v!==\"v\")process.exit(3);return db.close()}).then(()=>{console.log(\"classic-level OK via \"+p);process.exit(0)}).catch(e=>{console.error(e);process.exit(4)});
"; echo "EXIT=$?"' | tee /dev/stderr | grep -q 'EXIT=0'

echo "== 2. modbus-serial must be upstream, and connectRTUBuffered must not segfault (openp4nr fork does)"
runr 'apk add --no-cache socat >/dev/null 2>&1 || true
node -e "
const p=require(\"/usr/src/node-red/node_modules/@openp4nr/modbus-serial/package.json\");
if(p.name!==\"modbus-serial\"){console.error(\"override missing: \"+p.name);process.exit(2)}
console.log(\"modbus-serial resolved to upstream \"+p.version);
"
# A PTY pair stands in for the RS-485 line; we only need connect to return, not data.
if command -v socat >/dev/null; then
  socat -d -d pty,raw,echo=0,link=/tmp/ttyA pty,raw,echo=0,link=/tmp/ttyB >/dev/null 2>&1 & sleep 2
  node -e "
const M=require(\"/usr/src/node-red/node_modules/@openp4nr/modbus-serial\");const c=new M();
c.connectRTUBuffered(\"/tmp/ttyA\",{baudRate:9600}).then(()=>{console.log(\"connectRTUBuffered OK\");process.exit(0)}).catch(e=>{console.error(\"connect ERR\",e.message);process.exit(5)});
setTimeout(()=>process.exit(6),8000);
"; echo "EXIT=$?"
else echo "socat unavailable, PTY test skipped"; echo "EXIT=0"; fi' | tee /dev/stderr | grep -q 'EXIT=0'

echo "== 3. serialport must resolve its musl prebuild and udevadm must exist (port-scan button)"
run 'node -e "require(\"serialport\");console.log(\"serialport OK\")" && which udevadm && echo EXIT=0' | grep -q 'EXIT=0'

echo "== 4. Node-RED must boot to 18 modules with 0 errors and load the Tyrion plugin"
# Windows/MSYS note: python cannot see MSYS's /tmp, so keep the scratch file in cwd.
NODES_JSON="./.verify-nodes.json"
cid=$(docker run -d --platform linux/arm/v7 -p 18899:1880 "$IMAGE")
ok=0
for i in $(seq 1 45); do
  sleep 4
  if curl -sf http://localhost:18899/nodes -H 'Accept: application/json' -o "$NODES_JSON" 2>/dev/null; then
    mods=$(python -c "import json,sys;n=json.load(open(sys.argv[1]));print(len({m['module'] for m in n}))" "$NODES_JSON")
    errs=$(python -c "import json,sys;n=json.load(open(sys.argv[1]));print(sum(1 for m in n if m.get('err')))" "$NODES_JSON")
    plugin=$(docker logs "$cid" 2>&1 | grep -c 'Plugin loaded successfully' || true)
    echo "modules=$mods errors=$errs tyrionPluginLines=$plugin"
    [ "${mods:-0}" -ge 18 ] && [ "${errs:-1}" -eq 0 ] && [ "${plugin:-0}" -ge 1 ] && ok=1
    break
  fi
done
[ "$ok" -eq 1 ] || { echo "--- container log tail:"; docker logs --tail 25 "$cid" 2>&1; }
docker rm -f "$cid" >/dev/null; rm -f "$NODES_JSON"
[ "$ok" -eq 1 ] || { echo "BOOT CHECK FAILED"; exit 1; }
echo "== ALL CHECKS PASSED for $IMAGE"
