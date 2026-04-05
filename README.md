# npm-dependency-healer - セットアップガイド

## 概要

**npm-dependency-healer** は、GitHub Actions と GitHub Copilot CLI を組み合わせた、**npm 依存関係エラーの自動修復 CI** です。

Feature/Fix ブランチへの Push 時に依存解決・lint・型チェック・テストを自動実行し、エラーが検出された場合は Copilot が最大3ラウンドの修復ループを試みます。修復結果（成功・未完了を問わず）は必ず専用ブランチへコミットされ、PR として提出されます。main ブランチへの PR 時はビルドチェックのみ行い、失敗時は Copilot の分析レポートを Issue として自動投稿します。

```
Feature/Fixブランチ push
  └─ npm install → lint --fix → typecheck → test
       └─ エラー検出時: AI 修復ループ（最大 3 ラウンド）
            Round N: Copilot が修正コードを生成・適用
                     → npm install / lint / typecheck / test を再実行
                     → パス: final-status=passed で終了
                     → 失敗: エラーログを更新して次ラウンドへ
            ※ 3ラウンド消化後もテスト未通過の場合でも PR は作成する
       └─ 修復ブランチ <元ブランチ>_ai-fix-[RUN_ID] を Push
            PR 本文に修復結果バッジ（✅成功 / ⚠️未完了）と
            各ラウンドのログを記載

main ブランチ PR
  └─ npm run build
       └─ 失敗時: Copilot がエラー原因と修正案を分析
                  → GitHub Issue を自動作成してマージをブロック
                  ※ main への AI 直接修正は行わない
```

---

## 前提条件

| 要件 | バージョン / 条件 |
|------|-----------------|
| Node.js | 20.x 以上 |
| GitHub Actions | リポジトリで有効化済み |
| GitHub Copilot | **Copilot Business または Enterprise プラン** |

> ⚠️ `gh copilot suggest` / `gh copilot explain` は **Copilot Business/Enterprise** プランが必要です。個人の Copilot Individual プランでは CI 環境での動作が制限される場合があります。

---

## Step 1: Personal Access Token (PAT) の作成

GitHub Copilot CLI を Actions 環境で動作させるには、デフォルトの `GITHUB_TOKEN` では権限が不足するため、PAT が必要です。

### 1-1. PAT を発行する

1. GitHub → **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens**
2. **Generate new token** をクリック
3. 対象リポジトリを選択し、以下の権限を付与:

| Permission | Access |
|-----------|--------|
| **Contents** | Read and write |
| **Pull requests** | Read and write |
| **Issues** | Read and write |
| **Workflows** | Read and write |
| **Metadata** | Read-only（必須） |

4. **Expiration** に適切な有効期限を設定（推奨: 90日）
5. トークンをコピー（一度しか表示されません）

> 💡 Classic Token を使う場合は `repo`、`workflow`、`write:issues` スコープを付与してください。

### 1-2. PAT をシークレットに登録

```
リポジトリ → Settings → Secrets and variables → Actions → New repository secret
```

| Name | Value |
|------|-------|
| `GH_PAT` | 発行した PAT |

---

## Step 2: ファイルをリポジトリに配置

```
your-repo/
├── .github/
│   └── workflows/
│       └── self-healing.yml   ← ワークフローファイル
├── scripts/
│   └── ai-fix.sh              ← AI修復スクリプト（修復ループ内包）
└── SETUP.md                   ← このファイル
```

### スクリプトに実行権限を付与してコミット

```bash
chmod +x scripts/ai-fix.sh
git add .github/workflows/self-healing.yml scripts/ai-fix.sh SETUP.md
git commit -m "chore: add npm-dependency-healer CI"
git push
```

---

## Step 3: npm scripts の確認

`package.json` に以下のスクリプトが定義されていることを確認してください:

```json
{
  "scripts": {
    "lint": "eslint . --ext .ts,.tsx,.js,.jsx",
    "typecheck": "tsc --noEmit",
    "test": "jest",
    "build": "vite build"
  }
}
```

> スクリプト名が異なる場合は `self-healing.yml` 内の対応するコマンド行を適宜変更してください。

---

## Step 4: GitHub Actions のブランチ保護設定（推奨）

`main` ブランチへのマージを CI 通過後にのみ許可するよう設定します。

```
リポジトリ → Settings → Branches → Add branch ruleset
```

| 設定項目 | 値 |
|---------|---|
| Branch name pattern | `main` |
| Require status checks to pass | ✅ |
| Status checks に追加 | `Final Build Check (main)` |
| Require branches to be up to date | ✅ |

---

## Step 5: ラベルの作成（任意）

PR・Issue に自動でラベルを付けるために、以下のラベルをあらかじめ作成しておくと便利です。ラベルが存在しない場合でも CI は動作します（ラベル付与をスキップして続行）。

```
リポジトリ → Issues → Labels → New label
```

| ラベル名 | 推奨カラー | 用途 |
|---------|-----------|------|
| `ai-fix` | `#0075ca` | AI が作成した修復 PR |
| `build-failure` | `#e4e669` | ビルド失敗の分析 Issue |

---

## 動作確認

### Feature ブランチでの自動修復テスト

```bash
# わざとエラーを混入させてプッシュ
git checkout -b feature/test-healer
echo "const x: string = 123;" >> src/index.ts   # TypeScript 型エラー
git add . && git commit -m "test: introduce type error"
git push origin feature/test-healer
```

期待される動作:

1. Actions が起動し、typecheck / test のエラーを検出
2. `ai-fix.sh` が最大 3 ラウンドの修復ループを実行
3. ラウンド内で全テストがパスすれば `final-status=passed`、パスしなければ `final-status=failed` を記録
4. **結果に関わらず** `feature/test-healer_ai-fix-XXXXX` ブランチへコミットして PR を自動作成
5. PR 冒頭に `✅ 修復結果: 成功` または `⚠️ 修復結果: 未完了` バッジが表示される
6. PR の折りたたみセクションに各ラウンドの修復ログが記録される

### main ブランチへの PR でのビルドチェックテスト

```bash
git checkout -b fix/test-build-check
# ビルドエラーを意図的に混入
git add . && git commit -m "test: introduce build error"
git push origin fix/test-build-check
# GitHub 上で main への PR を作成
```

期待される動作:

1. `npm run build` が失敗
2. Copilot がエラーログを解析して原因と修正案を生成
3. 分析内容を本文にした Issue が自動作成される
4. CI が `exit 1` でマージをブロック

---

## トラブルシューティング

### ❌ `gh copilot` コマンドが失敗する

**原因**: Copilot Business/Enterprise プランに加入していない、または PAT の認証が切れている。

**対処**:
1. GitHub 組織の Copilot ライセンス設定を確認する
2. PAT に適切なスコープが付与されているか確認する
3. ローカルで `gh auth status` を実行してログイン状態を確認する

### ❌ ai-fix ブランチが無限に生成されてしまう

`_ai-fix-` を含むブランチはワークフローの `if` 条件で除外されているため、通常は発生しません。発生した場合は以下を確認してください:

```yaml
if: |
  github.ref != 'refs/heads/main' &&
  !contains(github.ref, '_ai-fix-') &&   # ← ループ防止
  github.event_name == 'push'
```

### ❌ PR 作成時に `Resource not accessible by integration` エラー

**原因**: デフォルトの `GITHUB_TOKEN` が使われており権限が不足している。

**対処**: `GH_PAT` シークレットが正しく登録されているか確認してください。

### ❌ `git push` が失敗する

**原因**: PAT に `Contents: Write` または `Workflows: Write` 権限がない。

**対処**: Step 1 を再確認し、権限を付与した上で PAT を再発行して `GH_PAT` を更新してください。

### ❌ 3ラウンド消化しても同じエラーが残り続ける

Copilot が同じ修正を繰り返している可能性があります。PR に添付されたラウンドログを確認し、手動で修正を加えてください。特にプロジェクト固有の依存関係バージョン競合は、手動対応が必要なケースがあります。

---

## セキュリティ上の注意

| 項目 | 説明 |
|------|------|
| **修復ループは最大3ラウンド** | `MAX_RETRIES=3` で際限ない自動修正を防止 |
| **ai-fix ブランチはループしない** | `!contains(github.ref, '_ai-fix-')` でセルフトリガーを除外 |
| **bot コミットをスキップ** | `github.actor == 'github-actions[bot]'` でダブルトリガーを防止 |
| **main への AI 直接修正なし** | main PR 時は分析 Issue の作成のみ。コードは人間が修正する |
| **PAT の管理** | PAT は定期的にローテーションし、不要になったら即削除する |
| **AI コードは必ずレビュー** | 修復 PR はマージ前に必ず差分を人間が確認する |

---

## ファイル構成まとめ

```
.github/workflows/self-healing.yml
  ├── job: auto-fix-ci              # Feature/Fix ブランチ用
  │    ├── npm install
  │    ├── lint --fix
  │    ├── typecheck
  │    ├── test
  │    ├── (失敗時) scripts/ai-fix.sh を起動
  │    │    └── 修復ループ（最大3ラウンド）をスクリプト側で管理
  │    └── (常に) ai-fix ブランチ作成 + PR 作成
  │         └── PR 冒頭に ✅/⚠️ 修復結果バッジ
  │             折りたたみに各ラウンドのログを掲載
  │
  └── job: main-build-check         # main PR 用
       ├── npm run build
       └── (失敗時) Copilot 分析 + Issue 作成 + CI 失敗終了

scripts/ai-fix.sh
  ├── 前提チェック（gh CLI, gh-copilot extension）
  ├── for round in 1..MAX_RETRIES(3):
  │    ├── 依存関係エラーの修復（missing modules, peer deps）
  │    ├── エラーログからターゲットファイルを特定
  │    ├── gh copilot suggest で修正コードを生成・適用
  │    │    └── ファイルをラウンドごとにバックアップ（.bak.rN）
  │    ├── npm install / lint / typecheck / test を再実行
  │    ├── パス → /tmp/final-status=passed で exit 0
  │    └── 失敗 → エラーログ更新して次ラウンドへ
  └── 全ラウンド失敗 → /tmp/final-status=failed で exit 0
       ※ exit 0 で返すことでブランチ&PR作成を妨げない
```
