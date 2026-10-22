# wordpress-deploy-kit

**한국어** · [English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

<!-- translated-from: README.md sha256:b493d0e231ea -->

**Ubuntu 클라우드 서버에 운영용 WordPress를 한 번의 명령으로 배포하는** 파일 하나짜리 스크립트입니다. 그 한 명령이 Nginx + MariaDB + PHP-FPM + WordPress(중국어판) + Let's Encrypt HTTPS의 설치, 설정, 검증, 자동 갱신 설정까지 수행하며, 전체에 5~8분쯤 걸립니다.

## 기능

- **완전 자동**: 9개 단계를 차례로 실행하고, `set -e`와 ERR 트랩이 첫 실패에서 멈추며 줄 번호를 알려 주므로 망가진 채로 계속 돌지 않습니다
- **먼저 대화형 입력**: 처음에 다섯 가지만 묻습니다(도메인, DB 비밀번호 두 개, 알림 이메일, 확인). 이후는 무인으로 진행되고 파이프 입력도 됩니다
- **비밀번호 자동 생성**: 비밀번호 질문을 비워 두면 `/dev/urandom`에서 8자리(숫자 + 영문 대소문자) 난수를 만듭니다
- **공인 IP 자동 탐지**: ifconfig.me → ipify → 로컬 NIC의 3단 폴백으로 직접 입력이 필요 없습니다
- **여러 소스에서 WordPress 내려받기**: 로컬 압축 파일 → 공식 다운로드 주소 → 미러 순으로, 모두 시간 초과가 있습니다. **내려받은 뒤 `tar -tzf`로 압축 파일을 검증합니다**(구성이 바뀐 미러나 속도 제한은 wget이 0으로 끝나도 HTML 오류 페이지를 돌려줍니다). 실패하면 다음 소스로 자동 전환하고, 모두 실패하면 수동 복구 절차를 분명히 안내합니다
- **HTTPS 전면 관리**: certbot이 인증서를 발급하고 Nginx를 SSL용으로 다시 쓰며 80 → 443 301을 강제합니다. systemd 타이머가 자동 갱신하고 배포 훅이 Nginx를 리로드합니다. 인증서 단계가 실패해도 경고만 하고 HTTP 사이트는 계속 동작합니다
- **자동 복구**: 손상된 MariaDB 데이터 디렉터리를 다시 만들고, PHP-FPM 소켓을 자동 탐지하며, 공식 API에 닿지 않으면 같은 수준의 Salts를 로컬에서 생성합니다
- **업로드 한도 상향**: nginx `client_max_body_size 512m`와 PHP `upload_max_filesize/post_max_size 512M`로 백업 플러그인이나 큰 미디어가 413으로 막히지 않습니다
- **미디어 라이브러리 동작**: `php-gd` / `php-imagick`과 mbstring/xml/curl/zip/intl을 기본 설치합니다. Nginx `try_files`가 `index.php`로 폴백하므로 고유주소와 `/wp-json` REST 업로드가 모두 동작합니다
- **저메모리 자동 조정**: `/proc/meminfo`를 보고 이미지 엔진을 고르는 mu-plugin을 기록합니다(2G 미만은 GD, 2G 이상은 Imagick 선호). 저메모리에서는 1536/2048 썸네일을 생략하고 큰 이미지 축소를 꺼서 원본 해상도로 서비스합니다
- **저메모리 조정**(물리 RAM이 1G 미만일 때만. 그 이상은 건드리지 않음): 스왑이 없으면 1G 스왑 파일을 만들어 켜고, PHP-FPM `memory_limit`이 `-1`이거나 128M을 넘으면 128M으로 좁혀(요청 하나가 전체 RAM을 먹지 않도록) 풀을 `ondemand`로 바꾸고 RAM에서 `max_children`을 계산합니다. `WPDK_SKIP_LOWMEM_TUNE=1`로 생략할 수 있습니다
- **재실행 안전**: 이미 배포된 머신에서 다시 실행해도 비밀번호나 데이터베이스가 이미 있다는 이유로 멈추지 않습니다. 기존 `wp-config.php`는 백업하고 그대로 복원합니다
- **기본으로 강화**(모든 단계가 멱등이며 재실행 가능):
  - 실제 비밀번호를 `/etc/mysql/debian.cnf`에 채워 넣어 **매일 자정 `logrotate.service` 실패**를 해결(기본값이 "root + 빈 비밀번호"인데 §3이 root를 비밀번호 인증으로 바꾸므로 반드시 `Access denied`를 남기게 됨)
  - `uploads/` 아래에서 PHP 실행 금지(업로드 디렉터리는 정적 파일만 제공. 가장 흔한 getshell 경로를 막고 이미지 등 정적 파일은 그대로 동작)
  - `DISALLOW_FILE_EDIT`를 `wp-config.php`에 기록해 관리 화면에서 플러그인/테마 코드를 편집할 수 없게 함
  - mu-plugin으로 **XML-RPC**(`system.multicall` 비밀번호 증폭, pingback 악용)와 **사용자 열거**(REST `/wp/v2/users`, `?author=N`) 차단
  - Nginx `server_tokens off`, `readme.html`과 `wp-config.php` 직접 접근 차단
  - 보안 업데이트 자동 적용을 켬. Ubuntu 20.04에서는 무료 Ubuntu Pro/ESM 활성화를 권장
  - **`/root/.ssh/authorized_keys`에 공개 키가 있으면** "키 전용 로그인 + 무차별 대입 저항"(`MaxAuthTries 3` / `MaxStartups`)으로 전환. 대화형 실행에서는 15분 자동 롤백 안전망을 걸어 둠
- **저메모리 PHP-FPM 조정**: 물리 RAM에서 `pm=ondemand` / `max_children` / `max_requests`를 정해, 동시 접속이나 wp-cron이 풀을 포화시킬 때의 503을 줄입니다
- **자격 증명 보관**: 주요 자격 증명을 `/root/wp-credentials-<domain>.txt`(모드 600, root 전용)에 기록하고, 평문 비밀번호가 담긴 배포 로그를 남기지 말라고 알립니다
- **마지막에 주요 자격 증명 모두 출력**: DB 비밀번호, 인증서 경로, 관리 스크립트 사용법을 한곳에 보여 주고 배포 후 상태 점검도 합니다

## 요구 사항

| 항목 | 요구 |
| --- | --- |
| OS | **Ubuntu 20.04(권장)**, 22.04 / 24.04도 가능(Debian 계열) |
| 권한 | root |
| 네트워크 | 인바운드 80 / 443 개방(클라우드 보안 그룹에서 열기) |
| HTTPS(선택) | 이 서버로 이미 해석되는 도메인. 도메인이 없으면 인증서 단계를 건너뜀 |
| 로컬 | ssh / scp(스크립트 업로드용) |

> **OS 버전 조언**: 작은 VPS(1 vCPU, 1G/2G RAM)에서는 Ubuntu 20.04 이미지를 권장합니다. 최신 릴리스는 구성 요소가 무거워 메모리를 더 쓰고, 1~2G 머신에서는 설치나 평상시 동작이 끊기거나 멈출 수 있습니다. 2G 이상이면 지원되는 어느 릴리스든 괜찮습니다. 저메모리 머신에서는 배포 전에 스왑을 추가하세요(예: `fallocate -l 1G /swapfile`).

## 빠른 시작

### 배포 단계

```bash
# 1. 업로드
scp wp_deploy.sh root@<server-ip>:/root/

# 2. 실행
ssh root@<server-ip>
bash /root/wp_deploy.sh

# 3. 끝나면 http://<domain-or-ip>/를 열고 WordPress 설치 마법사를 마무리
```

처음에 다섯 가지를 묻습니다(모두 Enter로 기본값 수용):

| # | 질문 | Enter 기본값 |
| --- | --- | --- |
| 1 | 도메인 | 공인 IP를 `server_name`으로 사용(HTTPS 생략) |
| 2 | MariaDB root 비밀번호 | 자동 생성 |
| 3 | WordPress DB 비밀번호 | 자동 생성 |
| 4 | Let's Encrypt 알림 이메일 | 비워 둠(갱신은 되지만 만료 메일이 오지 않음) |
| 5 | 확인 | 배포 시작 |

### 무인 실행(파이프 입력)

```bash
printf 'example.com\n<root password>\n<db password>\nyou@example.com\ny\n' | bash /root/wp_deploy.sh
```

비밀번호에 빈 줄을 주면 자동 생성됩니다. 예를 들어 둘 다 자동 생성하려면:

```bash
printf 'example.com\n\n\nyou@example.com\ny\n' | bash /root/wp_deploy.sh
```

### 선택 환경 변수(기본값이 권장값입니다)

| 변수 | 효과 | 필요한 상황 |
| --- | --- | --- |
| `WPDK_ALLOW_XMLRPC=1` | XML-RPC 엔드포인트 유지(기본은 차단) | **WordPress 모바일 앱**이나 Jetpack 사용 |
| `WPDK_SKIP_SSH_HARDEN=1` | "키 전용 로그인" 강화 생략(공개 키가 있으면 기본 활성) | 먼저 키를 확인하고 싶거나 다른 로그인 수단이 있음 |
| `WPDK_SKIP_LOWMEM_TUNE=1` | 저메모리 조정 생략(스왑도 `memory_limit`도 변경하지 않음) | RAM이 1G 미만이지만 자체 메모리/스왑 설계가 있음 |

```bash
# 예: 사이트에 WP 모바일 앱이 필요하고 SSH는 건드리지 않아야 함
WPDK_ALLOW_XMLRPC=1 WPDK_SKIP_SSH_HARDEN=1 bash /root/wp_deploy.sh
```
> 서버가 WordPress 압축 파일을 내려받지 못하면 [latest-zh_CN.tar.gz](https://cn.wordpress.org/latest-zh_CN.tar.gz)를 로컬에 받아 `scp latest-zh_CN.tar.gz root@<server-ip>:/root/wp_latest_zh.tar.gz`로 올린 뒤 스크립트를 다시 실행하세요. 올려 둔 압축 파일을 자동으로 씁니다.

## 배포 단계

| 단계 | 하는 일 |
| --- | --- |
| §2 | Nginx 설치와 부팅 시 자동 시작 |
| §3 | MariaDB 설치. 비대화형 강화(root 비밀번호 설정, 익명 사용자와 test DB 삭제) 실행. 소켓을 기다린 뒤 **`/etc/mysql/debian.cnf`에 실제 비밀번호를 채움**(매일 logrotate 실패 해결) |
| §4 | `wordpress` 데이터베이스(utf8mb4)와 localhost 전용 사용자 생성 |
| §5 | PHP-FPM과 WordPress 단골 확장(mysql/gd/imagick/mbstring/xml/curl/zip/intl) 설치, 실제 소켓 경로 탐지. **RAM에서 FPM 풀 조정**(ondemand / max_children / max_requests). **1G 미만 추가 조정**: 필요하면 1G 스왑 생성, `memory_limit`을 128M으로 축소 |
| §6 | Nginx 사이트 설정을 백업한 뒤 다시 씀(PHP FastCGI, `try_files` → `index.php`, server_name). `nginx -t`가 통과하면 적용. **uploads PHP 차단, `server_tokens off`, 민감 파일 차단 포함** |
| §7 | 임시 `info.php`를 두고 로컬 curl로 Nginx ↔ PHP-FPM 경로를 확인한 뒤 즉시 삭제 |
| §8 | 중국어판 WordPress를 여러 소스에서 검증하며 받아 `wp-config.php`(DB 설정과 무작위 Salts) 생성 |
| §9 | `/var/www/html`에 배치하고, RAM에서 GD/Imagick을 고르는 mu-plugin을 기록하고, 소유자를 `www-data`로 바꾸고, 로컬 curl로 홈페이지 확인. **사용자 열거·XML-RPC 차단 mu-plugin과 `DISALLOW_FILE_EDIT`도 기록** |
| §10 | certbot을 설치해 Let's Encrypt 인증서를 발급하고 80 → 443을 강제하며 자동 갱신을 설정(도메인이 없으면 생략) |
| §11 | 보안 기준과 상태 점검: 자동 업데이트, logrotate 재확인, 키 전용 SSH(키가 있을 때), 자격 증명 보관, 배포 후 점검 |

### HTTPS 자동 갱신

Let's Encrypt 인증서는 90일 유효합니다. §10 이후 서버에는 무인 갱신 체인이 갖춰집니다:

1. **certbot.timer**(systemd): 하루 두 번 확인하고 만료 30일 전에 갱신. 타이머가 없으면 `/etc/cron.d` 폴백을 기록
2. **배포 훅**: `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`가 갱신 성공 후 새 인증서로 Nginx를 리로드
3. **갱신 리허설**: 배포 끝에 `certbot renew --dry-run`으로 스테이징 환경을 상대로 체인 전체를 시험

### 인증서 수동 관리

스크립트는 서버에 `/root/cert_manage.sh`를 만듭니다:

```bash
bash /root/cert_manage.sh status    # 인증서(도메인/만료/경로)
bash /root/cert_manage.sh renew     # 수동 갱신(만료가 가까울 때만)
bash /root/cert_manage.sh force     # 지금 즉시 재발급(Let's Encrypt 속도 제한 주의)
bash /root/cert_manage.sh dryrun    # 갱신 리허설
bash /root/cert_manage.sh reissue   # 재발급 후 적용(인증서 단계가 실패한 뒤)
```

## 장애 시 동작과 자동 복구

| 상황 | 스크립트 동작 |
| --- | --- |
| 어느 단계든 실패 | `set -e` + ERR 트랩이 즉시 멈추고 실패한 줄과 문맥을 출력 |
| MariaDB 기동 실패(데이터 디렉터리 손상) | 데이터 디렉터리를 다시 만들고 재시도하며, 최대 30초 소켓을 폴링 |
| MySQL root 비밀번호가 설정된 상태로 재실행 | 비밀번호 없음/있음 로그인을 자동 전환 |
| 데이터베이스가 이미 있는 상태로 재실행 | `CREATE DATABASE IF NOT EXISTS`로 멱등 |
| 공식 다운로드 주소가 속도 제한(429)이거나 도달 불가 | 미러와 공식을 차례로 시도하고, 모두 실패하면 수동 복구 절차를 출력 |
| Salts API 도달 불가 | `/dev/urandom`에서 같은 수준의 무작위 Salts를 로컬 생성 |
| 백업/미디어 업로드가 413 | 이미 상향함: nginx `client_max_body_size 512m` + PHP `upload/post 512M` |
| 미디어 라이브러리 업로드가 반응 없음 | `php-gd`/`php-imagick` 설치됨. Nginx는 WordPress `try_files` 사용(`/wp-json` 지원) |
| 미디어 업로드가 느림(작은 VPS) | mu-plugin이 GD를 선호하고 1536/2048 썸네일을 생략. 그래도 느리면 원본을 압축 |
| 재실행이 사이트 설정을 덮어씀 | 배포 전에 `wp-config.php`를 백업하고 뒤에 그대로 복원하므로 사이트↔DB 연결이 바뀌지 않음 |
| **설치된** 사이트에서 재실행 | §9의 배포 후 점검이 `200/301/302`를 허용(설치된 사이트는 200)하므로 실패해 중단하지 않음 |
| 인증서 발급 실패(DNS 미반영, 80 차단 등) | 경고만 하고 HTTP 사이트는 계속 동작. 나중에 `reissue` 실행 |
| apt가 대화형 대화 상자를 요구 | 전체에서 `DEBIAN_FRONTEND=noninteractive` |
| `logrotate.service`가 매일 실패 | §3이 `/etc/mysql/debian.cnf`를 채우고 §11이 재확인. 유닛은 `inactive`로 돌아감 |
| uploads에 `.php`가 기록됨 | §6이 `location ^~ /wp-content/uploads/`를 두어 `.php/.phtml/.phar`는 403, 정적 파일은 영향 없음 |
| 사용자 열거(`?author=1`, `/wp-json/wp/v2/users`) | §9가 mu-plugin으로 차단. 일반 프런트와 관리 기능은 동작 |
| XML-RPC로 비밀번호 대입 | §9가 기본 차단. WP 모바일 앱을 위해 `WPDK_ALLOW_XMLRPC=1`로 유지 가능 |
| SSH 강화 후 잠김 | 강화는 `authorized_keys`에 키가 있을 때만 실행. 대화형 실행은 15분 자동 롤백을 걸고(`atrm <job>`로 취소), 무인 실행은 걸지 않음 |
| 작은 머신에서 동시 접속으로 503 | §5가 RAM에서 `pm=ondemand` + `max_children` + `max_requests` 설정 |
| 강화 단계를 다시 실행 | 모두 멱등: `;pm.max_requests` 같은 주석 줄도 인식하고, 기존 `define('DISALLOW_FILE_EDIT')`는 그대로 둠 |

## 백업과 복원

배포 키트에는 두 개의 보조 스크립트가 함께 제공됩니다. `wp_backup.sh`는 단일 자체 포함
아카이브를 만들고, `wp_restore.sh`는 동일한 OS 릴리스와 동일한 패키지 구성의 호스트에서
이를 복원합니다.

| 구성 요소 | 내용 |
| --- | --- |
| `db.sql` | `mysqldump --single-transaction --all-databases`(스키마, 데이터, 사용자와 권한) |
| `www.tar.gz` | `/var/www/html`(숫자 소유자 유지): `wp-config.php`, 플러그인, 테마, uploads, mu-plugins |
| `etc.tar.gz` | nginx(`nginx.conf`와 사이트 설정), PHP(`php.ini`, FPM 풀), `debian.cnf`, SSH 강화 drop-in, certbot cron, xray unit |
| `le.tar.gz` | `/etc/letsencrypt`(인증서와 갱신 설정) |
| `xray.tar.gz` | `config.json`(REALITY 개인 키와 UUID), 노드 URL, 관리 스크립트, 바이너리 |
| `manifest.txt` | OS, nginx, PHP, MariaDB, WordPress, 플러그인, xray 버전 목록 |

```bash
bash wp_backup.sh                                      # /root/wp-backups 출력, 7일 보관
_OUT_DIR_=/data/backups _KEEP_DAYS_=30 bash wp_backup.sh
_SKIP_MAINT_=1 bash wp_backup.sh                       # 유지보수 모드 생략
bash wp_restore.sh /root/wp-backups/wpbackup-<domain>-<timestamp>.tar.gz
```

- 백업 중에는 WordPress를 유지보수 모드로 전환합니다(보통 5~30초). 덤프와 파일 트리의
  일관성을 유지하고 완료 후 자동으로 해제합니다.
- 복원 대상은 **동일한 OS 릴리스의 깨끗한 호스트**를 전제로 합니다. 패키지를 설치하고,
  설정을 되돌리고, 데이터베이스를 가져오고, 파일을 소유자까지 복원한 뒤 서비스를
  재시작합니다.
- 실제 운영에서 만난 두 가지 실패 원인을 처리했습니다. `mysql` 스키마를 가져온 뒤
  `FLUSH PRIVILEGES`를 실행합니다(실행하지 않으면 WordPress 사용자가 `Access denied`가
  됩니다). 또한 노드 URL이 이전 주소를 그대로 담고 있으면 현재 공인 IP로 바꿉니다
  (REALITY 키는 그대로이고 주소만 바뀝니다).
- 아카이브에는 REALITY 개인 키, 데이터베이스 비밀번호, TLS 개인 키가 들어 있습니다.
  자격 증명으로 취급하고 다른 호스트에 사본을 보관하세요(권한은 `600`).

## FAQ

**Q: 배포가 중간에 실패하면?**
오류가 알려 준 원인(디스크, 네트워크, 보안 그룹 등)을 고치고 다시 실행하세요. 모든 단계가 멱등입니다.

**Q: 1 vCPU / 1G VPS에서도 되나?**
됩니다. 구성 요소가 가벼운 Ubuntu 20.04 이미지를 권장합니다. 최신 릴리스는 작은 머신에서 멈추기 쉽습니다. OOM 위험을 낮추려면 1G 스왑을 추가하세요.

**Q: 일부 구성 요소만 다시 설치할 수 있나?**
아니요. 이 스크립트는 머신 전체를 처음부터 배포하도록 설계되었습니다. 다시 만들려면 클라우드 콘솔에서 시스템 디스크를 초기화한 뒤 실행하세요.

**Q: `certbot renew --dry-run`에 몇 분 걸리는 게 정상인가?**
정상입니다. 비대화형 certbot 갱신은 ACME 서버에 접속하기 전에 무작위 대기(최대 8분)를 두어 부하를 분산합니다.

**Q: 도메인 없이 배포할 수 있나?**
됩니다. 도메인 질문에서 Enter를 누르면 공인 IP가 사이트 주소가 되고 §10 인증서 단계만 생략됩니다. 나중에 도메인을 이 서버로 돌린 뒤 `bash /root/cert_manage.sh reissue`로 HTTPS를 추가하세요.

**Q: 스크립트가 DB 비밀번호를 출력하는데 안전한가?**
자격 증명은 현재 SSH 세션에만 나오고 `/root/wp-credentials-<domain>.txt`(모드 600, root 전용)에도 기록됩니다.
⚠️ `bash wp_deploy.sh | tee deploy.log`처럼 실행 로그를 남기면 **그 로그에 평문 비밀번호가 남습니다**(실제 사례: 어떤 서버의 `/root/wp_deploy_run.log`에 MariaDB root 비밀번호가 그대로 있었다). 그런 로그는 `chmod 600` 하거나 지우고, 비밀번호는 비밀번호 관리자에 보관하세요.

## 보안 권장 사항

### 스크립트가 자동으로 하는 일

- uploads에서 PHP 실행 불가, `server_tokens off`, `readme.html` / `wp-config.php` 직접 접근 차단
- XML-RPC와 사용자 열거 차단. 관리 화면의 파일 편집기 비활성화(`DISALLOW_FILE_EDIT`)
- `/etc/mysql/debian.cnf` 채움(매일 `logrotate` 실패 해결). 보안 업데이트 자동 적용
- 공개 키가 감지되면 키 전용 로그인 + 무차별 대입 저항(롤백: `rm -f /etc/ssh/sshd_config.d/99-hardening.conf && sshd -t && systemctl reload ssh`)
- MariaDB는 localhost에서만 대기, 3306은 외부에 노출하지 않음

### 직접 하셔야 할 일

- **WordPress 관리자 비밀번호**: 설치 마법사에서 강한 비밀번호를 정하고 **TOTP 전용** 2단계 인증 플러그인을 켜세요(복구 코드를 먼저 보관)
- **호스트 수준의 보험**: 클라우드 콘솔의 VNC/원격 접속이 되는지 확인(키가 필요 없는 유일한 입구). 가능하면 스냅샷도 켜세요
- **백업**: UpdraftPlus 등에서 일정을 설정하세요 — 백업 플러그인을 설치만 하고 예약을 잡지 않는 사이트가 많은데, 그건 백업이 아닙니다
- **시스템 패치**: Ubuntu 20.04의 표준 지원은 2025년 5월에 끝났습니다. `pro attach`로 무료 ESM을 켜거나 22.04/24.04로 올릴 계획을 세우세요

## 개발 규칙(RepoRules)

이 저장소는 기계적 검사(인코딩/줄바꿈/Markdown 링크)에 [RepoRules](https://github.com/yanxijian/RepoRules)를 쓰고, 검사기를 저장소에 내장합니다:

```bash
python scripts/repo_rules.py check     # 검사
python scripts/repo_rules.py fix       # 자동 복구(줄바꿈, BOM 등)
git config core.hooksPath .githooks    # 클론마다 한 번: 커밋 전 검사
```

- 텍스트 파일은 UTF-8(BOM 없음). `.sh` / `.md`는 LF이며 `.gitattributes`로 고정합니다.
- CI는 RepoRules 저장소를 체크아웃해 `sync --check`를 실행합니다. 내장 사본이 업스트림보다 뒤지면 빌드가 실패합니다. 갱신은 RepoRules 체크아웃에서 `python repo_rules.py sync --root <this repo> --hook`으로 합니다.

## 라이선스

[MIT](./LICENSE) © 2026 wordpress-deploy-kit contributors
