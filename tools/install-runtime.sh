#!/usr/bin/env bash
# install-runtime.sh —— 把工作台自带的 RP-Hub 运行时铺到本地，并装上通信桥
#
#   tools/install-runtime.sh              # 用工作台内置的 1.8.9 快照
#   tools/install-runtime.sh path.zip     # 用你自己下载的上游 zip（根目录须含 RP-Hub-main/）
#   tools/install-runtime.sh --force      # 已存在也重铺
#   tools/install-runtime.sh --no-vendor  # 不把 CDN 依赖抓到本地（离线就用不了）
#
# 做的事：
#   1. 解出 RP-Hub-main/（默认取 CYF综合工作台.html 里的 Zaojing.baseline.archiveBase64）
#   2. 把 index.html 里 5 个 CDN <script> 抓成 vendor/ 下的本地文件并改写引用
#   3. 把 tools/workbench-bridge.js 拷进去
#   4. 在 RP-Hub-main/index.html 的 </body> 前引入它（已引入则跳过）
#
# 为什么要抓 CDN：上游 RP-Hub 的 Vue / Tailwind / marked / DOMPurify / Sortable
# 全部走 CDN。不抓的话，断网时 Vue 加载不出来，整个运行时根本起不来，试玩必然失败。
#
# 重复执行安全：已存在且完整时不做任何事。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HTML="$ROOT/CYF综合工作台.html"
RUNTIME="$ROOT/RP-Hub-main"
BRIDGE="$HERE/workbench-bridge.js"

ZIP=""
FORCE=0
VENDOR=1
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --no-vendor) VENDOR=0 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ZIP="$arg" ;;
  esac
done

[ -f "$BRIDGE" ] || { echo "✗ 找不到桥文件：$BRIDGE" >&2; exit 2; }
if [ -z "$ZIP" ]; then
  [ -f "$HTML" ] || { echo "✗ 找不到工作台页面：$HTML" >&2; exit 2; }
else
  [ -f "$ZIP" ] || { echo "✗ 找不到 zip：$ZIP" >&2; exit 2; }
fi

python3 - "$ROOT" "$HTML" "$RUNTIME" "$BRIDGE" "$ZIP" "$FORCE" "$VENDOR" <<'PY'
import base64, io, os, re, shutil, sys, urllib.request, zipfile

root, html, runtime, bridge, zip_path, force, vendor = sys.argv[1:8]
force = force == '1'
vendor = vendor == '1'

BRIDGE_TAG = '<script src="workbench-bridge.js"></script>'
CDN = [
    ('https://cdn.tailwindcss.com', 'tailwind.js'),
    ('https://unpkg.com/vue@3/dist/vue.global.prod.js', 'vue.global.prod.js'),
    ('https://cdn.jsdelivr.net/npm/marked/marked.min.js', 'marked.min.js'),
    ('https://cdn.jsdelivr.net/npm/dompurify@3.0.6/dist/purify.min.js', 'purify.min.js'),
    ('https://cdn.jsdelivr.net/npm/sortablejs@latest/Sortable.min.js', 'Sortable.min.js'),
]

def die(msg):
    print('✗ ' + msg, file=sys.stderr)
    sys.exit(1)

def extract_embedded(page):
    src = open(page, encoding='utf-8').read()
    m = re.search(r'archiveBase64\s*=\s*"([A-Za-z0-9+/=]+)"', src)
    if not m:
        die('工作台页面里找不到内置运行时快照（archiveBase64）')
    try:
        return base64.b64decode(m.group(1))
    except Exception as exc:
        die('内置运行时快照解码失败：%s' % exc)

def extract_zip(blob, source):
    try:
        zf = zipfile.ZipFile(io.BytesIO(blob))
    except Exception as exc:
        die('%s 不是有效的 zip：%s' % (source, exc))
    names = zf.namelist()
    if not any(n.startswith('RP-Hub-main/') for n in names):
        die('%s 里没有 RP-Hub-main/ 目录，请确认是上游仓库打包的 zip' % source)
    # 清掉旧的再铺，避免上一版残留的文件混进来
    if os.path.isdir(runtime):
        shutil.rmtree(runtime)
    zf.extractall(root)
    return len([n for n in names if not n.endswith('/')])

if not force and os.path.isfile(os.path.join(runtime, 'index.html')) \
        and os.path.isfile(os.path.join(runtime, 'workbench-bridge.js')):
    print('✓ 运行时已就位，无需重铺：%s' % runtime)
    sys.exit(0)

if zip_path:
    blob, source = open(zip_path, 'rb').read(), zip_path
else:
    blob, source = extract_embedded(html), '内置快照'

count = extract_zip(blob, source)
index = os.path.join(runtime, 'index.html')
if not os.path.isfile(index):
    die('铺完之后没看到 RP-Hub-main/index.html，zip 结构可能不对')

page = open(index, encoding='utf-8').read()

# --- 把 CDN 依赖抓到本地 -------------------------------------------------
if vendor:
    vdir = os.path.join(runtime, 'vendor')
    os.makedirs(vdir, exist_ok=True)
    vendored, kept = [], []
    for url, name in CDN:
        if 'src="%s"' % url not in page:
            continue
        target = os.path.join(vdir, name)
        if not os.path.isfile(target) or os.path.getsize(target) == 0:
            try:
                # 有些 CDN 对默认的 Python UA 直接 403
                req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (workbench-installer)'})
                with urllib.request.urlopen(req, timeout=45) as resp:
                    data = resp.read()
                if not data:
                    raise RuntimeError('下载到 0 字节')
                with open(target, 'wb') as fh:
                    fh.write(data)
            except Exception as exc:
                kept.append('%s（%s）' % (name, exc))
                continue
        page = page.replace('src="%s"' % url, 'src="vendor/%s"' % name)
        vendored.append(name)
    print('✓ 本地化 CDN：%s' % ('、'.join(vendored) if vendored else '（无）'))
    if kept:
        print('⚠ 这几个没抓到，仍走 CDN，断网时可能起不来：%s' % '、'.join(kept))

# --- 装通信桥 ------------------------------------------------------------
shutil.copyfile(bridge, os.path.join(runtime, 'workbench-bridge.js'))

if 'workbench-bridge.js' in page:
    injected = False
else:
    i = page.rfind('</body>')
    if i < 0:
        die('RP-Hub-main/index.html 里找不到 </body>，没法引入通信桥')
    page = page[:i] + '    ' + BRIDGE_TAG + '\n' + page[i:]
    injected = True

open(index, 'w', encoding='utf-8').write(page)

print('✓ 运行时：%s（%d 个文件，来源 %s）' % (runtime, count, source))
print('✓ 通信桥：%s' % os.path.join(runtime, 'workbench-bridge.js'))
print('✓ index.html：%s' % ('已引入 workbench-bridge.js' if injected else '已经引入过，跳过'))
PY
