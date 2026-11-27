# VSCodeCline_Portable

**VSCode / Cline ポータブル環境構築ツール**

VSCode ZIP 版、日本語パック、Cline、ポータブル Git（MinGit）、Playwright MCP を同じフォルダ配下で導入・起動・管理し、ローカル PC の Microsoft Edge と連携する Windows 用ランチャーです。

## 動作条件

- Windows（Windows PowerShell 5.1、tar.exe を使用）
- 配置先フォルダへの書き込み権限（ショートカットを作成する親フォルダを含む）
- 初回導入、不足する構成要素の追加、オンライン更新時のインターネット接続
- 利用時ClineのLLMを動作させるAPIキー、ネットワーク接続

管理者権限や、別途インストールした Node.js / npm は不要です（ブラウザーにはローカル PC の Microsoft Edge を使用します）。
Node.js の処理には VSCode 内蔵のランタイムを使用します。

## 使い方

|1.初回インストール<br>※途中20倍速再生|2.次回以降の起動|
|:--:|:--:|
|https://github.com/user-attachments/assets/9ec0ba71-377f-46c3-a055-5e335aa2e657|https://github.com/user-attachments/assets/b5f0a597-4ed7-4d60-bb21-7698c29a13fa|

1. USBデバイス等にこのリポジトリのソースZIPを展開します。
2. `src` フォルダの `Start-VSCodeCline_Portable.cmd` を実行します。
3. 不足する構成要素の導入と動作確認が完了すると、日本語で VSCode が起動します。
4. Cline の API プロバイダーや認証情報を設定します。

初回導入では VSCode、日本語パック、Cline、ポータブル Git（MinGit）、Playwright MCP をダウンロードします（専用 Chromium はダウンロードせず、ローカル PC の Microsoft Edge を利用します）。
既存のポータブル環境でも Git が未導入の場合は、次回のランチャー起動時に自動でインストールします。
導入済みの場合も、起動のたびに構成を確認し、ローカル Microsoft Edge のヘッドレス起動と MCP の接続・ツール一覧取得を検証します。

Cline の保存先を適用するため、通常は `Code.exe` を直接実行せず、このランチャー経由で起動してください。
同じポータブル版が起動済みの場合は、既存のウィンドウが使用されることがあります。

### 起動ショートカット

ランチャー実行時に、`src` の親フォルダへ `Start-VSCodeCline_Portable.cmd - 起動.lnk` を自動生成します。
ショートカットから起動すると、導入・動作確認の後に管理メニューを表示します。

- `--setup-only` 指定時も生成します。
- 既存リンクのリンク先・起動引数などが異なる場合は更新し、一致する場合は書き換えません。
- 移動後にリンクが起動できない場合は、移動先の `src` 内のランチャーを直接実行してください。

### 起動オプション

| 指定 | 動作 |
| --- | --- |
| 指定なし | 導入・動作確認後に VSCode を起動 |
| `--menu` | 導入・動作確認後に管理メニューを表示 |
| `--setup-only` | 導入・動作確認のみ実行し、VSCode や管理メニューは開かず終了 |
| ファイル／フォルダのパス | 導入・動作確認後に指定したパスを VSCode で開く |

`--setup-only` と `--menu` を両方指定した場合は、`--setup-only` が優先されます。
空白を含むパスは引用符で囲んでください。開くパスの指定は、`--menu` や `--setup-only` を付けない通常起動で使用します。

## 配置と保存先

VSCode の配置先は、常に **`src` の隣にある `VSCode` フォルダ**です。
ランチャーの場所を基準に決定するため、実行時のカレントフォルダや固定のドライブ文字には依存しません。
また、作業ファイルや認証情報、一時ファイル等はホスト OS 側に書き出されず、すべて `VSCode\data` 配下に封じ込められます。

```text
親フォルダ
├─ README.md
├─ Start-VSCodeCline_Portable.cmd - 起動.lnk  管理メニュー用ショートカット（自動生成）
├─ src/
│  ├─ Start-VSCodeCline_Portable.cmd          ランチャー本体（src 直下はこの 1 ファイルのみ）
│  └─ modules/                                モジュール・スクリプト・テンプレート格納先
│     ├─ Common-Helpers.ps1 / 他 *.ps1        起動・導入・更新・単体テスト処理
│     ├─ start-mcp.js / verify-mcp.js         MCP 起動・動作確認スクリプト
│     └─ playwright-mcp-snapshot.md           Cline グローバルルール同梱テンプレート
└─ VSCode/                                    Start-VSCodeCline_Portable.cmd の実行で自動生成
   ├─ Code.exe / その他の本体ファイル
   └─ data/                                   すべての作業ファイル・認証情報をこの配下に集約
      ├─ argv.json                            起動設定
      ├─ user-data/                           VSCode の設定・状態・ログ
      ├─ extensions/                          日本語パック・Cline 等の拡張機能
      ├─ tmp/                                 導入・更新用の一時ファイル、Add-Type 一時領域、npm キャッシュ
      ├─ home/                                ポータブル仮想ホーム (USERPROFILE / HOME)
      │  ├─ .cline/                           Cline の設定ルート (CLINE_DIR かつ ~/.cline / 旧 data\cline から自動移行)
      │  │  ├─ rules/
      │  │  │  └─ playwright-mcp-snapshot.md  自動配置される Playwright MCP スナップショット運用ルール
      │  │  ├─ data/settings/                 Cline 設定 (cline_mcp_settings.json 等)
      │  │  ├─ compatibility/backups/         互換修正時のバックアップ（該当時のみ）
      │  │  └─ mcp/playwright/                MCP サーバー・ブラウザープロファイル（Edge 専用分離領域）
      │  ├─ .ssh/                             ポータブル SSH ルート (known_hosts, 鍵ファイル / NTFS ACL 保護)
      │  ├─ .gitconfig                        ポータブル Git グローバル設定
      │  ├─ .npmrc                            npm ユーザー設定
      │  └─ .config/gh/                       GitHub CLI 設定
      ├─ appdata/                             ポータブル AppData (Roaming / Local / LocalLow / PSReadLine 履歴等)
      ├─ git/                                 ポータブル Git 管理領域
      │  ├─ system.gitconfig                  ホスト Program Files への include を遮断した Git 設定
      │  └─ gcm-dpapi/                        GCM DPAPI 暗号化クレデンシャル保存先 (NTFS ACL 保護)
      └─ tools/
         ├─ git/                              ポータブル Git (MinGit、実行ファイルは cmd/git.exe)
         └─ bin/                              ポータブル SSH シム群 (ssh, ssh-keygen, scp 等)
```

`VSCode` フォルダとその配下は、`Start-VSCodeCline_Portable.cmd` の導入処理や、起動後の VSCode / Cline / MCP の利用に応じて自動的に作成されます。事前に手動で作成する必要はありません。

### 展開フォルダ外への作業ファイル流出防止（完全ポータブル分離）

本ツールでは、ホスト PC への痕跡残留を防ぎ安全に利用できるよう、プロセスツリー単位で以下の分離を実施しています。

- **Cline 設定・グローバルルール**: `CLINE_DIR` およびポータブルホームを `data\home\.cline` に統合。どの作業フォルダを開いても `rules\playwright-mcp-snapshot.md`（Playwright MCP スナップショット運用ルール）が自動適用されます。
- **Git / GitHub 認証情報**: Git Credential Manager (GCM) は Windows 資格情報マネージャー（OS 側）を使わず、`data\git\gcm-dpapi` に Windows DPAPI で暗号化保存します（平文保存禁止）。また MinGit システム設定からホスト側 Git 設定の `[include]` を遮断します。
- **SSH 鍵・known_hosts**: `data\tools\bin` のシムおよび `GIT_SSH` 経由で MinGit 同梱 OpenSSH を使用し、`data\home\.ssh` 配下に保存します。NTFS 環境では `.ssh` および `gcm-dpapi` のアクセス権を実行ユーザーのみに制限します。
- **一時ファイル・コマンド履歴**: `TEMP` / `TMP` を `data\tmp` に固定し、PowerShell 履歴やキャッシュも `data\appdata` 内に限定します。

### 別の場所・PC への移動

VSCode と関連プロセスを終了してから、`src` と `VSCode` を同じ親フォルダに置いたまま移動してください。
バックアップも両フォルダをまとめて取得してください。

移動後の起動時に、ショートカットと管理対象 MCP の実行パスを更新します。
旧バージョンで作成された `VSCode\data\cline` がある場合も、起動時に新パス `VSCode\data\home\.cline` へ自動移行されます。
ユーザーが追加した設定内の絶対パスは自動変換しません。
認証情報や履歴を含む可能性があるため、保存先の取り扱いに注意してください。

## ポータブル Git

Git for Windows の公式リリースから軽量版の MinGit ZIP を取得し、公開された SHA-256 を検証したうえで自動インストールします。管理者権限やホスト PC への Git の事前インストールは不要です。
保存先は、この README の隣にある `VSCode` フォルダ配下の `data\tools\git` です。

- ランチャーから起動した VSCode、その統合ターミナル、Cline で `git --version` などの Git コマンドを実行できます。
- PATH への追加は子プロセスだけに適用し、Windows のユーザー／システム PATH は変更しません。
- 導入時にポータブル版 VSCode が起動済みだった場合は、すべて閉じてランチャーから起動し直してください。既存プロセスには新しい PATH が反映されません。
- 通常起動では導入済みのポータブル Git をそのまま再利用し、毎回再ダウンロードは行いません。最新バージョンの確認および更新は管理メニュー `[6]` から実行できます。
- MinGit はコマンド用の軽量版で、Git Bash／GUI は含みません。ユーザー名・メールアドレス・認証情報は自動設定しません。

### アプリケーション制御ポリシー（Smart App Control / WDAC）環境での動作とフォールバック

リムーバブルメディア上の未署名 DLL やプロセス実行を制限するセキュリティポリシー（Smart App Control、WDAC、AppLocker 等）が有効な Windows 環境でも安全・確実に利用できるよう、多層レジリエンス設計を採用しています。

1. **ホスト PC 正規 Git への自動フォールバック（完全分離維持）**:
   ポータブル MinGit の実行がコード整合性ポリシー（`0xC0E90002` 等）によりブロックされた場合、ホスト PC 上に正規導入されている Git（Authenticode 署名検証済み）を自動検出しフォールバックします。この場合でも、設定（`system.gitconfig`, `.gitconfig`）、認証情報（GCM DPAPI）、仮想ホーム（`HOME`）はすべて `VSCode\data` 配下に 100% 封じ込められ、ホスト OS 側への設定書き出しや認証情報の流出はありません。
2. **システム署名済み OpenSSH への自動フォールバック**:
   ポータブル同梱の `MinGit\usr\bin\ssh.exe` がブロックされた場合、またはホスト Git 連携時は、Windows 標準搭載・正規署名済みの OpenSSH（`%SystemRoot%\System32\OpenSSH`）へ自動切替します。専用のシムにより `-F` および `-o UserKnownHostsFile` をポータブル側 `data\home\.ssh` へ明示指定し、ホスト側 `.ssh` の混入・流出を遮断します。
3. **グレースフル・デグラデーション（縮退起動）と復旧ガイダンス**:
   ポータブル Git がブロックされ、かつホスト PC 上に利用可能な Git が存在しない場合でも、ランチャーは異常停止せず Git 機能を除いた状態で VSCode、Cline、Playwright MCP を正常起動します。
   - **初回接続直後の一時保留**: 別 PC への接続直後、Defender / クラウド評価の保留により一時的に `0xC0E90002` が発生した場合は、**OS を再起動**することでポータブル Git が実行可能になる場合があります。
   - **組織ポリシーによる恒久制限**: リムーバブルメディア実行が恒久的に禁止されている環境では、ホスト PC に公式 [Git for Windows](https://git-scm.com/download/win) を導入することで、次回起動時から自動連携されます。

## 管理メニュー

ショートカット、または `--menu` を付けたランチャーから開きます。
メニューを表示する前にも、通常起動と同じ導入・動作確認を実行します。

| 番号 | 機能 |
| --- | --- |
| 1 / Enter | ポータブル版 VSCode を起動 |
| 2 | 開くファイルまたはフォルダを指定して起動 |
| 3 | ポータブル用フォルダ・初期設定を作成／修復 |
| 4 | `VSCode` 配下の `data` フォルダを開く |
| 5 | 通常版 VSCode / Cline から設定・拡張機能をコピー |
| 6 | VSCode / Cline / Playwright MCP / Git のアップデート管理 |
| 0 | 終了 |

### 通常版からの設定コピー

メニューの `[5]` では、次の項目を個別に確認してコピーします。自動導入ではコピーしません。

- VSCode ユーザー設定：`%APPDATA%\Code\User`
- VSCode 拡張機能：`%USERPROFILE%\.vscode\extensions`
- Cline 設定：`%USERPROFILE%\.cline\data\settings`

コピー元は変更しませんが、ポータブル側の同名ファイルは上書きします。
両方の VSCode を終了し、コピー先をバックアップしてから実行してください。
設定内の絶対パスは変換しません。Cline の履歴全体を移行する機能ではありません。

### 更新

メニューの `[6]` から、**VSCode 本体・Cline・Playwright MCP・ポータブル Git (MinGit)** の最新バージョン確認、4 要素の一括オンライン更新、個別オンライン更新、およびローカルパッケージからのオフライン適用ができます。
他の導入済み拡張機能（日本語パック等）の更新も選択できます。

- 更新前は、対象のポータブル版 VSCode と関連プロセス（MCP / Edge / Git）を終了してください。
- 本体・MCP の更新では `data`・Cline 設定を保持し、ファイル入れ替えや動作確認に失敗した場合は更新前の状態への復元を試みます。
- Playwright MCP の新規導入およびオンライン更新では、npm レジストリから最新の安定版 `@playwright/mcp` を取得し、ローカル PC の Microsoft Edge との接続・ツール一覧取得を自動検証します。
- ローカル更新では、VSCode ZIP、MinGit ZIP、拡張機能の VSIX、または `@playwright/mcp` の TGZ を指定します。`VSCode` 直下のパッケージ（`.zip` / `.vsix` / `.tgz`）は候補として表示されます。
- ローカルパッケージの適用自体はオンライン照会を行いません。また、メニュー表示前に不足する構成要素があればダウンロードが必要です。

ランチャーの通常起動時の導入処理は、不足する構成要素を追加するもので、導入済みの要素を毎回最新版へ自動更新する処理ではありません。最新版への引き上げはメニューの `[6]` から実行してください。

## 設定・互換性に関する注意

- エディターの初期設定は、設定ファイルがない場合のみ作成します（自動保存を `afterDelay`、保存時整形を無効化）。また、ランチャー管理外のバックグラウンド更新で互換処理が未適用になるのを防ぐため、`extensions.autoUpdate` が未設定の場合は既定で `false` に設定します（ユーザーが明示設定した場合はその値を保持します）。
- Cline の MCP サーバー `playwright` に、同梱スクリプトと VSCode 内蔵ランタイムを登録します。管理対象の起動設定は起動時に更新しますが、他の MCP サーバーや既存の承認設定は保持し、ツールの自動承認は追加しません。
- MCP はローカル PC の Microsoft Edge を使用し、作業ファイルやプロファイルは `VSCode\data` 配下の専用フォルダに分離して保持します。
- ホストのユーザー／システム環境変数は書き換えず、Cline の保存先等は子プロセスの環境に設定します。
- ハードリンク非対応のファイルシステム（exFAT / FAT32 等）では、導入・更新・起動時に Cline の MCP 設定読み込み互換修正をバージョン別の事前 SHA-256 バックアップおよび整合性検証付きで自動適用します（Cline 4.1.26 / 4.1.27 以降に対応。将来の上流版でハードリンクが廃止された場合は自動で無改変スキップし、未知のハードリンク形式が残存する場合は警告を表示します）。
- オンライン取得する VSCode ZIP は配布元の SHA-256 がある場合に照合し、導入用 npm は SHA-512 を照合します。ローカル ZIP は別途ハッシュ照合を行わないため、信頼できる配布元を使用してください。

## エラー時の確認

導入や動作確認に失敗した場合はエラーを表示して終了します。
ネットワーク、書き込み権限、空き容量を確認して再実行してください。不足する構成要素は再度導入を試みます。
VSCode のログは `VSCode` 配下の `data\user-data\logs` に保存されます。

exFAT 互換修正で元コードの不一致が報告された場合や、更新後の復元が完了していない場合は、エラーに表示されたバックアップを保全してください。

非対話実行でエラー時の一時停止（`pause`）を抑止するには、プロセス環境変数 `PORTABLE_NONINTERACTIVE=1` を設定します。
この変数は、導入・更新中の確認入力を自動承認するものではありません。
