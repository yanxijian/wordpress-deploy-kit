# wordpress-deploy-kit

**日本語** · [English](README.md) · [简体中文](README.zh-CN.md) · [한국어](README.ko.md)

[![hygiene](https://github.com/yanxijian/wordpress-deploy-kit/actions/workflows/hygiene.yml/badge.svg)](https://github.com/yanxijian/wordpress-deploy-kit/actions/workflows/hygiene.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu-E95420.svg)](https://ubuntu.com/)

<!-- translated-from: README.md sha256:721c813ed748 -->

**Ubuntu のクラウドサーバーに本番用 WordPress をワンコマンドで構築する** 1 ファイルのスクリプトです。その 1 コマンドで Nginx + MariaDB + PHP-FPM + WordPress（中国語版）+ Let's Encrypt HTTPS の導入、設定、検証、自動更新の設定まで行います。全体で 5〜8 分ほどです。

## 特長

- **全自動**：9 つの段階を順に実行し、`set -e` と ERR トラップで最初の失敗で止まって行番号を報告するので、壊れたまま動き続けることはありません
- **最初に対話で入力**：最初に 5 つだけ尋ねます（ドメイン、データベースのパスワード 2 つ、通知メール、確認）。以降は無人で進み、パイプ入力にも対応します
- **パスワードの自動生成**：パスワードの問い合わせを空のままにすると、`/dev/urandom` から 8 文字（数字＋英大文字小文字）の乱数を生成します
- **公開 IP の自動検出**：ifconfig.me → ipify → ローカル NIC の 3 段フォールバックで、手入力は不要です
- **複数ソースからの WordPress 取得**：ローカルのアーカイブ → 公式のダウンロード先 → ミラー、いずれもタイムアウト付き。**取得後は `tar -tzf` でアーカイブを検証します**（構成が変わったミラーやレート制限は wget が 0 で終わっても HTML のエラーページを返すため）。失敗すれば次のソースへ自動で進み、全部だめなら手動での復旧手順を明示します
- **HTTPS を完全に管理**：certbot が証明書を発行し、Nginx を SSL 用に書き換えて 80 → 443 の 301 を強制します。systemd タイマーが自動更新し、デプロイフックが Nginx をリロードします。証明書の段階が失敗しても警告だけにとどめ、HTTP のサイトは動き続けます
- **自己修復**：壊れた MariaDB のデータディレクトリを再作成し、PHP-FPM のソケットを自動検出し、公式 API に届かないときは同等の Salts をローカルで生成します
- **アップロード上限を引き上げ**：nginx の `client_max_body_size 512m` と PHP の `upload_max_filesize/post_max_size 512M` により、バックアップ系プラグインや大きなメディアが 413 で弾かれなくなります
- **メディアライブラリが動く**：`php-gd` / `php-imagick` と mbstring/xml/curl/zip/intl を既定で導入。Nginx の `try_files` は `index.php` にフォールバックするので、パーマリンクも `/wp-json` 経由の REST アップロードも動きます
- **少メモリ向けの自動調整**：`/proc/meminfo` を見て画像エンジンを選ぶ mu-plugin を書き込みます（2G 未満は GD、2G 以上は Imagick を優先）。少メモリでは 1536/2048 のサムネイルを省き、大きな画像の縮小は無効にして原寸のまま配信します
- **少メモリ調整**（物理メモリが 1G 未満のときだけ。それ以上は何もしません）：スワップが無ければ 1G のスワップファイルを作成して有効化。PHP-FPM の `memory_limit` が `-1` か 128M 超なら 128M に絞り（1 リクエストが全メモリを食い尽くさないように）、プールを `ondemand` にして RAM から `max_children` を計算します。`WPDK_SKIP_LOWMEM_TUNE=1` で省略できます
- **再実行しても安全**：すでに構築済みのマシンで再実行しても、パスワードやデータベースが既にあるという理由で止まりません。既存の `wp-config.php` はバックアップし、そのまま復元します
- **既定で堅牢化**（すべて冪等で再実行可能）：
  - 実際のパスワードを `/etc/mysql/debian.cnf` に反映 → **毎日 0 時の `logrotate.service` 失敗**を解消（既定は「root + 空パスワード」で、§3 が root をパスワード認証に切り替えるため、必ず `Access denied` を記録してしまう）
  - `uploads/` 配下での PHP 実行を禁止（アップロード先は静的ファイルのみ。最も多い getshell の経路を塞ぎ、画像などの静的ファイルはそのまま動く）
  - `DISALLOW_FILE_EDIT` を `wp-config.php` に書き込み、管理画面からプラグイン／テーマのコードを編集できなくする
  - mu-plugin で **XML-RPC**（`system.multicall` によるパスワード増幅、pingback の悪用）と**ユーザー列挙**（REST `/wp/v2/users`、`?author=N`）を遮断
  - Nginx の `server_tokens off`、`readme.html` と `wp-config.php` への直接アクセスを遮断
  - セキュリティ更新の自動適用を有効化。Ubuntu 20.04 では無償の Ubuntu Pro/ESM の有効化を勧める
  - **`/root/.ssh/authorized_keys` に公開鍵がある場合**は「鍵のみのログイン＋総当たり耐性」に切り替え（`MaxAuthTries 3` / `MaxStartups`）。対話実行では 15 分の自動ロールバック網を張る
- **少メモリ向けの PHP-FPM 調整**：物理 RAM から `pm=ondemand` / `max_children` / `max_requests` を設定し、同時接続や wp-cron でプールが飽和したときの 503 を減らします
- **資格情報の保存**：主要な資格情報は `/root/wp-credentials-<domain>.txt`（モード 600、root のみ）に書き出し、平文パスワードを含むデプロイログを残さないよう注意を促します
- **最後に主要な資格情報をすべて表示**：データベースのパスワード、証明書のパス、管理スクリプトの使い方をまとめて出し、デプロイ後のヘルスチェックも行います

## 動作要件

| 項目 | 要件 |
| --- | --- |
| OS | **Ubuntu 20.04（推奨）**、22.04 / 24.04 も可（Debian 系） |
| 権限 | root |
| ネットワーク | 受信 80 / 443 が開いていること（クラウドのセキュリティグループで開放） |
| HTTPS（任意） | このサーバーに解決済みのドメイン。ドメインが無い場合、証明書の段階は省略されます |
| ローカル | ssh / scp（スクリプトの転送用） |

> **OS 版の選び方**：小さな VPS（1 vCPU、1G/2G RAM）では Ubuntu 20.04 のイメージを推奨します。新しい版は同梱物が重くメモリを使うため、1〜2G のマシンでは導入や通常運用がたつき、止まってしまうこともあります。2G 以上ならどの対応版でも構いません。少メモリのマシンでは、デプロイ前にスワップを足してください（例：`fallocate -l 1G /swapfile`）。

## クイックスタート

### デプロイ手順

```bash
# 1. 転送
scp wp_deploy.sh root@<server-ip>:/root/

# 2. 実行
ssh root@<server-ip>
bash /root/wp_deploy.sh

# 3. 終わったら http://<domain-or-ip>/ を開き、WordPress のセットアップを済ませる
```

最初に 5 つ尋ねます（いずれも Enter で既定値）：

| # | 問い合わせ | Enter の既定 |
| --- | --- | --- |
| 1 | ドメイン | 公開 IP を `server_name` に使う（HTTPS は省略） |
| 2 | MariaDB の root パスワード | 自動生成 |
| 3 | WordPress データベースのパスワード | 自動生成 |
| 4 | Let's Encrypt の通知メール | 空のまま（更新は動くが、期限切れの通知が来ない） |
| 5 | 確認 | デプロイ開始 |

### 無人実行（パイプ入力）

```bash
printf 'example.com\n<root password>\n<db password>\nyou@example.com\ny\n' | bash /root/wp_deploy.sh
```

パスワードを空行にすると自動生成されます。たとえば両方とも自動生成するには：

```bash
printf 'example.com\n\n\nyou@example.com\ny\n' | bash /root/wp_deploy.sh
```

### 任意の環境変数（既定値が推奨値です）

| 変数 | 効果 | 必要な場面 |
| --- | --- | --- |
| `WPDK_ALLOW_XMLRPC=1` | XML-RPC のエンドポイントを残す（既定は遮断） | **WordPress モバイルアプリ**や Jetpack を使うとき |
| `WPDK_SKIP_SSH_HARDEN=1` | 「鍵のみのログイン」の堅牢化を省略（公開鍵があれば既定で有効） | 先に鍵を確認したい、他のログイン手段がある |
| `WPDK_SKIP_LOWMEM_TUNE=1` | 少メモリ調整を省略（スワップも `memory_limit` も変更しない） | RAM は 1G 未満だが独自のメモリ／スワップ設計がある |

```bash
# 例：サイトで WP モバイルアプリを使い、SSH は一切触らない
WPDK_ALLOW_XMLRPC=1 WPDK_SKIP_SSH_HARDEN=1 bash /root/wp_deploy.sh
```
> サーバーが WordPress のアーカイブを取得できない場合は、[latest-zh_CN.tar.gz](https://cn.wordpress.org/latest-zh_CN.tar.gz) を手元に落とし、`scp latest-zh_CN.tar.gz root@<server-ip>:/root/wp_latest_zh.tar.gz` で送ってからもう一度スクリプトを実行してください。送ったアーカイブを自動で使います。

## デプロイの段階

| 段階 | 行われること |
| --- | --- |
| §2 | Nginx を導入し、自動起動を有効化 |
| §3 | MariaDB を導入。非対話の堅牢化（root パスワード設定、匿名ユーザーとテスト DB の削除）を実行。ソケットを待ち、**`/etc/mysql/debian.cnf` に実際のパスワードを反映**（毎日の logrotate 失敗を解消） |
| §4 | `wordpress` データベース（utf8mb4）と localhost 限定の専用ユーザーを作成 |
| §5 | PHP-FPM と WordPress で定番の拡張（mysql/gd/imagick/mbstring/xml/curl/zip/intl）を導入し、実際のソケットパスを検出。**RAM から FPM プールを調整**（ondemand / max_children / max_requests）。**1G 未満向けの追加調整**：必要なら 1G のスワップを作り、`memory_limit` を 128M に絞る |
| §6 | Nginx のサイト設定をバックアップしてから書き換え（PHP FastCGI、`try_files` → `index.php`、server_name）。`nginx -t` が通ってから反映。**uploads の PHP 遮断、`server_tokens off`、機密ファイルの遮断を含む** |
| §7 | 一時的な `info.php` を置き、ローカルの curl で Nginx ↔ PHP-FPM の経路を確認してから即座に削除 |
| §8 | 中国語版 WordPress を複数ソースから検証付きで取得し、`wp-config.php`（DB 設定とランダムな Salts）を生成 |
| §9 | `/var/www/html` に配置し、RAM から GD/Imagick を選ぶ mu-plugin を書き、所有者を `www-data` にして、ローカルの curl でトップページを確認。**ユーザー列挙・XML-RPC 遮断の mu-plugin と `DISALLOW_FILE_EDIT` も書き込む** |
| §10 | certbot を導入して Let's Encrypt の証明書を発行し、80 → 443 を強制、自動更新を設定（ドメインが無ければ省略） |
| §11 | セキュリティ基準とヘルスチェック：自動更新、logrotate の再確認、鍵のみの SSH（鍵がある場合）、資格情報の保存、デプロイ後チェック |

### HTTPS の自動更新

Let's Encrypt の証明書は 90 日有効です。§10 の後、サーバーには無人更新の連鎖が揃います：

1. **certbot.timer**（systemd）：1 日 2 回確認し、期限の 30 日前に更新。タイマーが無い場合は `/etc/cron.d` にフォールバックを書く
2. **デプロイフック**：`/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` が、更新成功後に新しい証明書で Nginx をリロードする
3. **更新のリハーサル**：デプロイの最後に `certbot renew --dry-run` で、ステージング環境に対して連鎖全体を試す

### 証明書の手動管理

スクリプトはサーバー上に `/root/cert_manage.sh` を生成します：

```bash
bash /root/cert_manage.sh status    # 証明書（ドメイン／期限／パス）
bash /root/cert_manage.sh renew     # 手動更新（期限が近いときだけ）
bash /root/cert_manage.sh force     # いますぐ強制再発行（Let's Encrypt のレート制限に注意）
bash /root/cert_manage.sh dryrun    # 更新のリハーサル
bash /root/cert_manage.sh reissue   # 再発行して導入（証明書の段階が失敗した後）
```

## 障害時の挙動と自己修復

| 状況 | スクリプトの挙動 |
| --- | --- |
| どこかの段階が失敗 | `set -e` と ERR トラップが即座に止め、失敗した行と前後の文脈を表示 |
| MariaDB が起動しない（データディレクトリの破損） | データディレクトリを作り直して再試行し、最大 30 秒ソケットをポーリング |
| MySQL の root パスワードが設定済みで再実行 | パスワード無しと有りのログインを自動で切り替え |
| データベースが既にある状態で再実行 | `CREATE DATABASE IF NOT EXISTS` で冪等 |
| 公式のダウンロード先がレート制限（429）か到達不能 | ミラーと公式を順に試し、全部だめなら手動の復旧手順を表示 |
| Salts の API に届かない | `/dev/urandom` から同等のランダム Salts をローカル生成 |
| バックアップ／メディアのアップロードが 413 | すでに引き上げ済み：nginx `client_max_body_size 512m` + PHP `upload/post 512M` |
| メディアライブラリのアップロードが無反応 | `php-gd`/`php-imagick` を導入済み。Nginx は WordPress の `try_files` を使う（`/wp-json` 対応） |
| メディアのアップロードが遅い（小さな VPS） | mu-plugin が GD を優先し 1536/2048 のサムネイルを省略。それでも遅ければ元画像を圧縮 |
| 再実行でサイト設定が上書きされる | デプロイ前に `wp-config.php` をバックアップし、後でそのまま復元するので、サイトと DB の結線は変わらない |
| **構築済み**のサイトで再実行 | §9 のデプロイ後チェックは `200/301/302` を受け付ける（構築済みなら 200）ので、失敗して中断しない |
| 証明書の発行に失敗（DNS 未反映、80 番が閉鎖など） | 警告のみで HTTP のサイトは動き続ける。後で `reissue` を実行 |
| apt が対話ダイアログを出そうとする | 全体で `DEBIAN_FRONTEND=noninteractive` |
| `logrotate.service` が毎日失敗する | §3 が `/etc/mysql/debian.cnf` を補正し、§11 で再確認。ユニットは `inactive` に戻る |
| uploads に `.php` が書かれた | §6 が `location ^~ /wp-content/uploads/` を持ち、`.php/.phtml/.phar` は 403、静的ファイルは影響なし |
| ユーザー列挙（`?author=1`、`/wp-json/wp/v2/users`） | §9 が mu-plugin で遮断。通常のフロント表示と管理機能は動く |
| XML-RPC を使ったパスワード総当たり | §9 が既定で遮断。WP モバイルアプリ用に `WPDK_ALLOW_XMLRPC=1` で残せる |
| SSH の堅牢化後に締め出された | 堅牢化は `authorized_keys` に鍵がある場合だけ実行。対話実行では 15 分の自動ロールバックを張る（`atrm <job>` で取消）。無人実行では張らない |
| 小さなマシンで同時接続による 503 | §5 が RAM から `pm=ondemand` + `max_children` + `max_requests` を設定 |
| 堅牢化の段階をもう一度実行 | すべて冪等：`;pm.max_requests` のようなコメント行も認識し、既存の `define('DISALLOW_FILE_EDIT')` はそのまま残す |

## バックアップとリストア

デプロイキットには 2 つの補助スクリプトが付属します。`wp_backup.sh` は単一の自己完結
アーカイブを生成し、`wp_restore.sh` は同じ OS リリースと同じパッケージ構成のホストで
それを復元します。

| 構成要素 | 内容 |
| --- | --- |
| `db.sql` | `mysqldump --single-transaction --all-databases`（スキーマ、データ、ユーザーと権限） |
| `www.tar.gz` | `/var/www/html`（数値オーナーを保持）: `wp-config.php`、プラグイン、テーマ、uploads、mu-plugins |
| `etc.tar.gz` | nginx（`nginx.conf` とサイト設定）、PHP（`php.ini`、FPM プール）、`debian.cnf`、SSH 強化用 drop-in、certbot の cron、xray の unit |
| `le.tar.gz` | `/etc/letsencrypt`（証明書と更新設定） |
| `xray.tar.gz` | `config.json`（REALITY 秘密鍵と UUID）、ノード URL、管理スクリプト、バイナリ |
| `manifest.txt` | OS、nginx、PHP、MariaDB、WordPress、プラグイン、xray のバージョン一覧 |

```bash
bash wp_backup.sh                                      # /root/wp-backups に出力、7 日保持
_OUT_DIR_=/data/backups _KEEP_DAYS_=30 bash wp_backup.sh
_SKIP_MAINT_=1 bash wp_backup.sh                       # メンテナンスモードを省略
bash wp_restore.sh /root/wp-backups/wpbackup-<domain>-<timestamp>.tar.gz
```

- バックアップ中は WordPress をメンテナンスモードにします（通常 5〜30 秒）。ダンプと
  ファイルツリーの整合性を保ち、終了後に自動で解除します。
- リストア先は**同じ OS リリースのまっさらなホスト**を前提とします。パッケージを導入し、
  設定を戻し、データベースをインポートし、ファイルをオーナーごと復元してからサービスを
  再起動します。
- 実運用で遭遇した 2 つの失敗要因に対処済みです。`mysql` スキーマをインポートした後に
  `FLUSH PRIVILEGES` を実行します（実行しないと WordPress ユーザーが `Access denied`
  になります）。また、ノード URL が以前のアドレスのままなら現在のパブリック IP に
  書き換えます（REALITY の鍵は変わらず、アドレスだけが変わります）。
- アーカイブには REALITY 秘密鍵、データベースのパスワード、TLS 秘密鍵が含まれます。
  認証情報として扱い、別ホストにコピーを保管してください（権限は `600`）。

## FAQ

**Q：デプロイの途中で失敗したら？**
エラーが示す原因（ディスク、ネットワーク、セキュリティグループなど）を直して、もう一度実行してください。どの段階も冪等です。

**Q：1 vCPU / 1G の VPS でも動く？**
動きます。同梱物が軽い Ubuntu 20.04 のイメージを推奨します。新しい版は小さなマシンで止まりがちです。OOM の危険を下げるため 1G のスワップを足してください。

**Q：一部のコンポーネントだけ入れ直せる？**
いいえ。このスクリプトはマシン全体を一から構築する設計です。作り直すには、クラウドのコンソールでシステムディスクをリセットしてから再実行してください。

**Q：`certbot renew --dry-run` に数分かかるのは普通？**
普通です。非対話の certbot 更新は、ACME サーバーに接続する前にランダムな待ち時間（最大 8 分）を置いて負荷を分散します。

**Q：ドメイン無しでデプロイできる？**
できます。ドメインの問い合わせで Enter を押すと公開 IP がサイトのアドレスになり、§10 の証明書の段階だけが省略されます。あとでドメインをこのサーバーに向けたら、`bash /root/cert_manage.sh reissue` で HTTPS を追加してください。

**Q：スクリプトがデータベースのパスワードを表示するのは安全？**
資格情報は現在の SSH セッションにだけ出て、`/root/wp-credentials-<domain>.txt`（モード 600、root のみ）にも書き出されます。
⚠️ `bash wp_deploy.sh | tee deploy.log` のように実行ログを残すと、**そのログに平文のパスワードが残ります**（実際にあった例：あるサーバーの `/root/wp_deploy_run.log` に MariaDB の root パスワードが残っていた）。そうしたログは `chmod 600` するか削除し、パスワードはパスワードマネージャーに保管してください。

## セキュリティ上の推奨

### スクリプトが自動で行うこと

- uploads で PHP を実行させない、`server_tokens off`、`readme.html` / `wp-config.php` への直接アクセスを遮断
- XML-RPC とユーザー列挙を遮断。管理画面のファイルエディタを無効化（`DISALLOW_FILE_EDIT`）
- `/etc/mysql/debian.cnf` を補正（毎日の `logrotate` 失敗を解消）。セキュリティ更新の自動適用を有効化
- 公開鍵を検出したら鍵のみのログイン＋総当たり耐性（ロールバック：`rm -f /etc/ssh/sshd_config.d/99-hardening.conf && sshd -t && systemctl reload ssh`）
- MariaDB は localhost のみで待ち受け、3306 は外部に出さない

### あなたがやること

- **WordPress の管理者パスワード**：セットアップで強いパスワードを設定し、**TOTP のみ**の二要素プラグインを有効に（回復コードは先に保管）
- **ホスト側の保険**：クラウドのコンソールの VNC／リモートアクセスが使えることを確認（鍵を必要としない唯一の入口）。可能ならスナップショットも有効に
- **バックアップ**：UpdraftPlus などでスケジュールを設定 — バックアッププラグインを入れたまま予約を取らないサイトが多く、それではバックアップになっていません
- **システムの更新**：Ubuntu 20.04 の標準サポートは 2025 年 5 月に終了しました。無償の ESM を `pro attach` で有効にするか、22.04/24.04 への更新を計画してください

## 開発の決まりごと（RepoRules）

本リポジトリは [RepoRules](https://github.com/yanxijian/RepoRules) を機械的な検査（文字コード／改行／Markdown リンク）に使い、チェッカーをリポジトリに同梱しています：

```bash
python scripts/repo_rules.py check     # 検査
python scripts/repo_rules.py fix       # 自動修復（改行、BOM など）
git config core.hooksPath .githooks    # クローンごとに 1 回：コミット前検査
```

- テキストファイルは UTF-8（BOM なし）。`.sh` / `.md` は LF で、`.gitattributes` で固定しています。
- CI は RepoRules リポジトリをチェックアウトして `sync --check` を実行します。同梱の副本が上流より古いとビルドが落ちます。更新は RepoRules のチェックアウトで `python repo_rules.py sync --root <this repo> --hook` を実行します。

## ライセンス

[MIT](./LICENSE) © 2026 wordpress-deploy-kit contributors
