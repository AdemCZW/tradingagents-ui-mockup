# shellcheck shell=bash
# 部署設定：每個專案只改這個檔。stage.sh / deploy.sh / verify-live.sh 都會 source 它。
# 注意：這是 bash 語法（陣列），腳本一律用 `bash tools/xxx.sh` 執行，不要用 zsh / sh。

# ── 來源專案資料夾 ─────────────────────────────────────────────
# 預設：本檔所在資料夾的上一層（樣板建議放在 <專案>/tools/）。
# 可用環境變數覆寫：PROJECT_DIR=/path/to/project bash tools/stage.sh <輸出目錄>
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── Worker 與網址 ──────────────────────────────────────────────
WORKER_NAME="tradingagents-ui-mockup"                       # 只能小寫英數與 -；會成為網址的第一段
WORKERS_SUBDOMAIN="${WORKERS_SUBDOMAIN:-tednologystudio}"   # 帳號的 workers.dev 子網域
LIVE_URL="https://${WORKER_NAME}.${WORKERS_SUBDOMAIN}.workers.dev"
COMPATIBILITY_DATE="2026-09-01"
# 帳號有多個時 wrangler 會問要用哪個；填了就不問（非機密，可留空）
CLOUDFLARE_ACCOUNT_ID_FOR_DEPLOY=""

# ── 部署前必須通過的測試（規格 §6.7）────────────────────────────
# 在 PROJECT_DIR 內依序執行，任一失敗就不部署。留空＝這次部署沒有回歸把關（會警告）。
# 例：PRE_DEPLOY_TESTS=(
#       "node --test tests/*.test.js"
#       "bash ../qa/run.sh . --reporter=line"
#     )
# 真的要跳過（例如只改文件）：SKIP_TESTS=1 bash tools/deploy.sh
PRE_DEPLOY_TESTS=()

# ── 白名單：只有這些會被複製上線 ─────────────────────────────────
# 相對於 PROJECT_DIR。可以是檔案、資料夾（整包複製）或 glob（例如 fonts/*.woff2）。
# 任何一項找不到就中止——寧可整理失敗，也不要少檔上線。
# 刻意不用 .assetsignore 之類的忽略檔：docs/、tests/ 常含客戶資訊，只能用白名單擋。
INCLUDE_PATHS=(
  index.html
  robots.txt
  _headers
)

# ── 品牌／客戶攔截字（ERE 正規表示式，不分大小寫；留空＝不掃）──────
# 例：BRAND_PATTERN='客戶甲|clienta|某某學院'
BRAND_PATTERN=""
# 二進位檔（圖片、字型中繼資料）用的攔截字；留空＝沿用 BRAND_PATTERN。
# 很短的英文字在二進位裡可能誤判，必要時在這裡改成較長的字。
BRAND_PATTERN_BINARY=""

# ── 掃描排除的第三方資料夾（資料夾名稱，任何層級都算）──────────────
# 例：vendor models（MediaPipe、Google 模型這類二進位，不排除會誤判）
SCAN_EXCLUDE_DIRS=(
)

# ── 不該部署的檔案（stage.sh 檢查、verify-live.sh 抽查線上 404）──────
FORBIDDEN_NAMES=('*.md' '*.test.js' '*.spec.js' '*.test.ts' '*.spec.ts' '.env*' 'wrangler.json' 'wrangler.jsonc' 'wrangler.toml' 'package.json' 'package-lock.json')
FORBIDDEN_DIRS=(docs tests test node_modules .git .wrangler .claude)

# 線上一定要回 404 的額外路徑（verify-live.sh 用；專案有已知敏感檔就加）
EXTRA_404_PATHS=(
)
