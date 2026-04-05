#!/usr/bin/env bash
# =============================================================================
# scripts/ai-fix.sh
# Self-Healing CI - GitHub Copilot によるエラー自動修復スクリプト
#
# 前提:
#   - gh CLI がインストール済み
#   - gh extension install github/gh-copilot 実行済み
#   - GH_TOKEN 環境変数が設定済み
#   - ERROR_LOG 環境変数: 初回エラーログファイルのパス
#
# 動作（修復ループ・最大3ラウンド）:
#   Round N:
#     1. エラーログを解析して影響ファイルを特定
#     2. gh copilot suggest で修正コードを生成・適用
#     3. テスト再実行（npm install → lint → typecheck → test）
#     4. パスすれば /tmp/final-status=passed で終了
#     5. 失敗なら次のラウンドへ（最大 MAX_RETRIES=3 まで）
#   全ラウンドの経過は /tmp/fix-rounds.log に追記する
#   最終ステータスは /tmp/final-status に書き出す
# =============================================================================

set -uo pipefail

# ── 設定 ──────────────────────────────────────────────────────────────────────
MAX_RETRIES=3
ERROR_LOG="${ERROR_LOG:-/tmp/all-errors.log}"
ROUNDS_LOG="/tmp/fix-rounds.log"
FINAL_STATUS_FILE="/tmp/final-status"

# ラウンドログ・ステータスファイルを初期化
> "$ROUNDS_LOG"
echo "failed" > "$FINAL_STATUS_FILE"

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[AI-FIX]${NC} $*"; }
log_success() { echo -e "${GREEN}[AI-FIX]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[AI-FIX]${NC} $*"; }
log_error()   { echo -e "${RED}[AI-FIX]${NC} $*"; }

# ラウンドログへも同時書き出し
round_log() {
  local round="$1"
  local msg="$2"
  local line="[Round ${round}] ${msg}"
  echo -e "${CYAN}${line}${NC}"
  echo "$line" >> "$ROUNDS_LOG"
}

# ── 前提チェック ───────────────────────────────────────────────────────────────
check_prerequisites() {
  log_info "Prerequisites check..."

  if ! command -v gh &>/dev/null; then
    log_error "gh CLI not found. Please install GitHub CLI."
    exit 1
  fi

  if ! gh extension list 2>/dev/null | grep -q "gh-copilot"; then
    log_warn "gh-copilot extension not found. Installing..."
    gh extension install github/gh-copilot --force || {
      log_error "Failed to install gh-copilot extension."
      exit 1
    }
  fi

  if [[ ! -f "$ERROR_LOG" ]]; then
    log_error "ERROR_LOG not found: $ERROR_LOG"
    exit 1
  fi

  log_success "Prerequisites OK."
}

# ── テストスイートを実行 ──────────────────────────────────────────────────────
# 戻り値: 0=全パス, 1=いずれか失敗
# ログ出力先: /tmp/round-${round}-*.log
run_tests() {
  local round="$1"
  local fail=0

  round_log "$round" "Running test suite..."

  npm install 2>&1 | tee "/tmp/round-${round}-install.log"
  [[ ${PIPESTATUS[0]} -ne 0 ]] && { round_log "$round" "  ❌ npm install failed"; fail=1; }

  npm run lint 2>&1   | tee "/tmp/round-${round}-lint.log"     || fail=1
  npm run typecheck 2>&1 | tee "/tmp/round-${round}-typecheck.log" || fail=1
  npm test 2>&1       | tee "/tmp/round-${round}-test.log"     || fail=1

  if [[ $fail -eq 0 ]]; then
    round_log "$round" "✅ All tests PASSED"
    return 0
  else
    round_log "$round" "❌ Tests FAILED — will collect new error log for next round"
    return 1
  fi
}

# ── ラウンドのエラーログを集約 ────────────────────────────────────────────────
collect_round_errors() {
  local round="$1"
  local out="/tmp/round-${round}-errors.log"

  {
    echo "=== Round ${round}: install ==="
    cat "/tmp/round-${round}-install.log"   2>/dev/null || echo "(no log)"
    echo ""
    echo "=== Round ${round}: lint ==="
    cat "/tmp/round-${round}-lint.log"      2>/dev/null || echo "(no log)"
    echo ""
    echo "=== Round ${round}: typecheck ==="
    cat "/tmp/round-${round}-typecheck.log" 2>/dev/null || echo "(no log)"
    echo ""
    echo "=== Round ${round}: test ==="
    cat "/tmp/round-${round}-test.log"      2>/dev/null || echo "(no log)"
  } > "$out"

  echo "$out"
}

# ── エラーログからソースファイルパスを抽出 ────────────────────────────────────
extract_target_files() {
  local error_log="$1"
  local -a files=()

  log_info "Extracting target files from error log..."

  while IFS= read -r line; do
    # TypeScript / ESLint: path/to/file.ts:10:5
    if [[ "$line" =~ ([a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|mjs|cjs))[\(:][0-9] ]]; then
      files+=("${BASH_REMATCH[1]}")
    fi
    # ESLint ファイルパス行（行頭がパスのみ）
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx))$ ]]; then
      files+=("${BASH_REMATCH[1]}")
    fi
    # webpack/vite: ERROR in ./src/App.tsx
    if [[ "$line" =~ ERROR[[:space:]]+in[[:space:]]+[./]*([a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx)) ]]; then
      files+=("${BASH_REMATCH[1]}")
    fi
  done < "$error_log"

  # 重複排除・実在ファイルのみ
  declare -A seen
  local -a unique_files=()
  for f in "${files[@]}"; do
    f="${f#./}"
    if [[ -z "${seen[$f]+_}" ]] && [[ -f "$f" ]]; then
      seen[$f]=1
      unique_files+=("$f")
    fi
  done

  echo "${unique_files[@]:-}"
}

# ── Copilot で修正コードを生成 ────────────────────────────────────────────────
generate_fix_with_copilot() {
  local target_file="$1"
  local error_log="$2"
  local round="$3"
  local output_file="/tmp/copilot-fix-r${round}-$(basename "$target_file")"

  log_info "  Generating fix: $target_file (round $round)"

  local current_content
  current_content=$(cat "$target_file" 2>/dev/null || echo "")

  local error_snippet
  error_snippet=$(grep -A2 -B2 "$(basename "$target_file")" "$error_log" 2>/dev/null | head -30 \
                  || head -30 "$error_log")

  local prompt
  prompt="以下のNode.js/TypeScriptファイルにエラーがあります。修正したコード全体を出力してください。

【対象ファイル】: ${target_file}
【修復ラウンド】: ${round} / ${MAX_RETRIES}

【エラーログ（抜粋）】:
${error_snippet}

【現在のファイル内容】:
\`\`\`
${current_content}
\`\`\`

【指示】:
- 修正後のコード全体を出力すること（省略禁止）
- コードブロック(\`\`\`)で囲むこと
- 型エラー・lintエラー・テストエラーをすべて修正すること"

  local suggestion
  suggestion=$(timeout 60 gh copilot suggest -t shell "$prompt" 2>/dev/null \
    || timeout 60 gh copilot explain "$prompt" 2>/dev/null \
    || echo "")

  if [[ -z "$suggestion" ]]; then
    log_warn "  Copilot returned empty suggestion (round $round, file: $target_file)"
    return 1
  fi

  # コードブロック抽出（言語指定あり→なし の順で試行）
  local fixed_code
  fixed_code=$(echo "$suggestion" | \
    awk '/```(typescript|javascript|tsx|jsx|ts|js)/{p=1;next} p && /```/{p=0;next} p')

  if [[ -z "$fixed_code" ]]; then
    fixed_code=$(echo "$suggestion" | \
      awk '/^```/{if(p){p=0}else{p=1};next} p')
  fi

  if [[ -z "$fixed_code" ]]; then
    log_warn "  Could not extract code block (round $round, file: $target_file)"
    return 1
  fi

  echo "$fixed_code" > "$output_file"
  echo "$output_file"
}

# ── ファイルのバックアップと置換 ──────────────────────────────────────────────
apply_fix() {
  local target_file="$1"
  local fix_file="$2"
  local round="$3"

  cp "$target_file" "${target_file}.bak.r${round}"
  cp "$fix_file" "$target_file"
  log_success "  Patched: $target_file (backup: ${target_file}.bak.r${round})"
  round_log "$round" "  → patched: $target_file"
}

# ── 依存関係エラーの修復 ──────────────────────────────────────────────────────
fix_dependency_errors() {
  local error_log="$1"
  local round="$2"

  local -a missing_modules=()
  while IFS= read -r line; do
    if [[ "$line" =~ Cannot\ find\ module\ \'([^\']+)\' ]]; then
      local mod="${BASH_REMATCH[1]}"
      [[ ! "$mod" =~ ^[./] ]] && missing_modules+=("$mod")
    fi
  done < "$error_log"

  if [[ ${#missing_modules[@]} -gt 0 ]]; then
    local unique_mods
    unique_mods=$(printf '%s\n' "${missing_modules[@]}" | sort -u | tr '\n' ' ')
    round_log "$round" "Installing missing modules: $unique_mods"
    # shellcheck disable=SC2086
    npm install $unique_mods 2>&1 | tee "/tmp/round-${round}-install-fix.log" || true
  fi

  if grep -qE "peer dep|ERESOLVE|incompatible" "$error_log" 2>/dev/null; then
    round_log "$round" "Peer dep conflict → retrying with --legacy-peer-deps"
    npm install --legacy-peer-deps 2>&1 | tee "/tmp/round-${round}-legacy.log" || true
  fi
}

# ── 1ラウンドの修復処理 ───────────────────────────────────────────────────────
# 戻り値: 0=修正を1件以上適用, 1=適用なし
run_fix_round() {
  local round="$1"
  local error_log="$2"
  local applied=0

  echo "" >> "$ROUNDS_LOG"
  round_log "$round" "==============================="
  round_log "$round" "  AI Fix Round ${round}/${MAX_RETRIES}"
  round_log "$round" "==============================="

  # 依存関係修復（先行して実施）
  fix_dependency_errors "$error_log" "$round"

  # 対象ファイルを特定
  local target_files_str
  target_files_str=$(extract_target_files "$error_log")

  if [[ -z "$target_files_str" ]]; then
    round_log "$round" "⚠️  No source files identified. Requesting general suggestion..."
    local general_suggestion
    general_suggestion=$(timeout 60 gh copilot suggest -t shell \
      "以下のNode.jsエラーの解決方法を教えてください: $(head -50 "$error_log")" \
      2>/dev/null || echo "(no suggestion)")
    echo "$general_suggestion" >> "$ROUNDS_LOG"
    return 1
  fi

  # ファイルごとに修正適用
  read -ra files <<< "$target_files_str"
  for target_file in "${files[@]}"; do
    local fix_file
    fix_file=$(generate_fix_with_copilot "$target_file" "$error_log" "$round") || {
      round_log "$round" "  ⚠️  Skipped: $target_file (no fix generated)"
      continue
    }
    if [[ -n "$fix_file" ]] && [[ -f "$fix_file" ]]; then
      apply_fix "$target_file" "$fix_file" "$round"
      applied=1
    fi
  done

  if [[ $applied -eq 0 ]]; then
    round_log "$round" "❌ No files were patched in this round."
    return 1
  fi

  return 0
}

# ── メイン: 修復ループ（最大 MAX_RETRIES ラウンド）────────────────────────────
main() {
  log_info "========================================"
  log_info "  Self-Healing CI - AI Fix Script"
  log_info "  Max rounds: ${MAX_RETRIES}"
  log_info "========================================"

  check_prerequisites

  local current_error_log="$ERROR_LOG"

  for round in $(seq 1 "$MAX_RETRIES"); do
    log_info "--- Repair round ${round}/${MAX_RETRIES} ---"

    # 修正適用
    if ! run_fix_round "$round" "$current_error_log"; then
      round_log "$round" "No fix applied. Stopping repair loop."
      break
    fi

    # 再テスト
    round_log "$round" "Re-running full test suite..."
    if run_tests "$round"; then
      echo "passed" > "$FINAL_STATUS_FILE"
      log_success "✅ All tests PASSED after round ${round}! Self-healing complete."
      exit 0
    fi

    # 次ラウンド用エラーログを更新
    current_error_log=$(collect_round_errors "$round")
    round_log "$round" "Updated error log for next round: $current_error_log"

    if [[ $round -lt $MAX_RETRIES ]]; then
      round_log "$round" "→ Proceeding to round $((round + 1))..."
    fi
  done

  # 全ラウンド消化してもテスト失敗
  echo "failed" > "$FINAL_STATUS_FILE"
  log_warn "⚠️  Exhausted all ${MAX_RETRIES} rounds. Tests still failing."
  log_warn "   Partial fixes have been staged. PR will be created for human review."

  # exit 0 で返してブランチ&PR作成を妨げない
  exit 0
}

main "$@"
