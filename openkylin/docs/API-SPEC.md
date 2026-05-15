# CAPEv2 `/apiv2/` 接口规范

> **生成依据**：直接从部署机 `192.168.1.6` 的源码抓取并解析
> 　·　`/opt/cape-deploy/CAPEv2/web/apiv2/urls.py` —— 82 条路由
> 　·　`/opt/cape-deploy/CAPEv2/web/apiv2/views.py` —— 117 KB view 实现
> 　·　`/opt/cape-deploy/CAPEv2/conf/api.conf` —— 每个 endpoint 的 enabled / auth_only / rate 配置
> 　·　`/opt/cape-deploy/CAPEv2/conf/web.conf` —— 全局 + GUI 配置
> 　·　CAPEv2 上游 commit `dd36c30` (HEAD on `kevoreilly/CAPEv2` 抓取当时)
>
> 本文档反映 **本次部署的实际状态**（api.conf 的 `enabled` 列是真值，不是 cape2.sh 默认值）。

---

## 目录

1. [基本信息](#1-基本信息)
2. [认证模型](#2-认证模型)
3. [限流](#3-限流)
4. [统一响应格式](#4-统一响应格式)
5. [本次部署的端点启用矩阵](#5-本次部署的端点启用矩阵)
6. [端点详表](#6-端点详表)
   - [6.1 提交任务（写入）](#61-提交任务写入)
   - [6.2 任务生命周期管理](#62-任务生命周期管理)
   - [6.3 任务搜索 / 列表](#63-任务搜索--列表)
   - [6.4 任务结果下载](#64-任务结果下载)
   - [6.5 文件 / 样本查询](#65-文件--样本查询)
   - [6.6 系统 / 机器信息](#66-系统--机器信息)
   - [6.7 其它](#67-其它)
7. [token 认证开启步骤（如需）](#7-token-认证开启步骤如需)
8. [附：常用 curl 示例](#8-附常用-curl-示例)

---

## 1. 基本信息

| 项 | 值 |
|---|---|
| **Base URL（本部署）** | `http://192.168.1.6:8090/apiv2/`（localhost 上 `http://127.0.0.1:8090/apiv2/`） |
| **协议** | HTTP/1.1（无 TLS；如要 HTTPS 自己挂 nginx 反代） |
| **承载** | Django 5.1 + DRF（`runserver_plus`，单进程） |
| **路由源** | `web/apiv2/urls.py` |
| **CSRF** | `tasks_create_*` 等用 `@csrf_exempt` 显式豁免，可纯 token 调用 |
| **CORS** | 未启用（同源策略；跨域调用需自己加 `django-cors-headers`） |
| **API 文档 HTML 索引** | `GET /apiv2/`（返回 HTML 帮助页，非 JSON） |

---

## 2. 认证模型

由 `conf/api.conf` `[api] token_auth_enabled` 单一开关控制：

```ini
[api]
token_auth_enabled = no       # 本部署当前 = no → 全开放
```

- `no`（**本部署**）→ DRF `DEFAULT_PERMISSION_CLASSES = [AllowAny]`，任何来源直接调，**含 localhost 和外网**。
- `yes` → DRF `DEFAULT_PERMISSION_CLASSES = [IsAuthenticated]` + `TokenAuthentication`，每次调用必须带 HTTP header：
  ```
  Authorization: Token <40-char hex token>
  ```

**重要：CAPE 没有"localhost 自动豁免"** ——
代码搜索过 `REMOTE_ADDR / INTERNAL_IPS / 127.0.0.1` 等模式，apiv2 view 内不存在 IP 白名单分支。
"同机服务能否绕过 auth" 取决于：(a) `token_auth_enabled = no` → 不用 token；(b) `= yes` → 必须 token（与外部一致）。如果想 localhost 免 token 但外部要 token，参考 `README.md` "方案 C 自定义中间件" 段。

### 单 endpoint 强制 token：`auth_only`

部分 endpoint 在 api.conf 有 `auth_only = yes`（**即使全局 token_auth_enabled = no 也强制**），目前仅 `[capeconfig]` 这么配。

### 取 token 的方式（一旦开了 token auth）

`POST /apiv2/api-token-auth/`，标准 DRF endpoint：
```bash
curl -X POST http://192.168.1.6:8090/apiv2/api-token-auth/ \
  -d "username=admin" -d "password=YOUR_PASS"
# → {"token":"xxx40hex..."}
```

---

## 3. 限流

`[api] ratelimit = yes` 启用。每个 endpoint 在 api.conf 单独配 `rps` (req/sec) + `rpm` (req/min)：

| Limit | 默认值 | 例外 |
|---|---|---|
| 普通用户 | `default_user_ratelimit = 5/m` | `is_staff = True` 用户无限制 |
| 订阅用户 | `default_subscription_ratelimit = 5/m` | 通过 Django admin 给 user.userprofile.subscription 设值覆盖 |
| **匿名（current）** | per-endpoint rps/rpm 字段；超限 → HTTP 429 | — |

实现在 `apiv2/throttling.py::SubscriptionRateThrottle`，**只有 token_auth_enabled = yes 时生效**。当前部署是 no → 限流被 DRF 跳过。

---

## 4. 统一响应格式

成功（JSON）：
```json
{
  "error": false,
  "data": {
    "message": "Task ID(s) [42] has been submitted",
    "task_ids": [42]
  },
  "url": ["http://example.tld/submit/status/42/"]
}
```

失败：
```json
{
  "error": true,
  "error_value": "File Create API is Disabled"
}
```

下载类 endpoint（report/pcap/screenshot/zip 等）直接返回二进制 + `Content-Type` + `Content-Disposition`。

---

## 5. 本次部署的端点启用矩阵

> ✅ = api.conf `enabled = yes`，可调用
> ❌ = `enabled = no`，调用会返回 `{"error":true,"error_value":"... API is Disabled"}` 但 HTTP 200
> 🔒 = `auth_only = yes`（即使 token_auth_enabled=no 也强制 token）

| api.conf section | endpoint(s) | 当前 | auth_only |
|---|---|---|---|
| `[filecreate]` | `POST tasks/create/file/` | ✅ | no |
| `[urlcreate]` | `POST tasks/create/url/` | ✅ | no |
| `[staticextraction]` | `POST tasks/create/static/` | ✅ | no |
| `[dlnexeccreate]` | `POST tasks/create/dlnexec/` | ❌ | no |
| `[downloading_services]` | `POST tasks/create/download_services/` | ❌ | no |
| `[tasklist]` | `GET tasks/list/...` | ✅ | no |
| `[taskview]` | `GET tasks/view/<id>/` | ✅ | no |
| `[taskstatus]` | `GET tasks/status/<id>/`, `POST tasks/get/stream/<id>/` | ✅ | no |
| `[taskresched]` | `GET tasks/reschedule/<id>/` | ❌ | no |
| `[taskreprocess]` | `GET tasks/reprocess/<id>/` | ❌ | no |
| `[taskdelete]` | `GET tasks/delete/<ids>/` + `POST tasks/delete_many/` | ❌ | no |
| `[tasksearch]` | `GET tasks/search/{md5\|sha1\|sha256}/<hash>/` | ✅ | no |
| `[extendedtasksearch]` | `POST tasks/extendedsearch/` | ✅ | no |
| `[fileview]` | `GET files/view/{md5\|sha1\|sha256\|id}/<v>/` | ✅ | no |
| `[sampledl]` | `GET files/get/<stype>/<value>/` | ❌ | no |
| `[taskreport]` | `GET tasks/get/report/<id>/...` | ✅ | no |
| `[taskiocs]` | `GET tasks/get/iocs/<id>/[detailed/]` | ✅ | no |
| `[capeconfig]` | `GET tasks/get/config/<id>/...` | ✅ | **🔒 yes** |
| `[taskscreenshot]` | `GET tasks/get/screenshot/<id>/[/<n>/]` | ✅ | no |
| `[taskpcap]` | `GET tasks/get/pcap/<id>/`, `tasks/get/pcap/<id>/<variant>/` | ✅ | no |
| `[tasktlspcap]` | `GET tasks/get/tlspcap/<id>/` | ✅ | no |
| `[tasktlskeys]` | `GET tasks/get/keys/<id>/<kind>/` | ✅ | no |
| `[tasketw]` | `GET tasks/get/etw/<id>/<kind>/` | ✅ | no |
| `[taskbulkzip]` | `GET tasks/get/bulkzip/<id>/<folder>/` | ✅ | no |
| `[taskevtx]` | `GET tasks/get/evtx/<id>/` | ✅ | no |
| `[taskdropped]` | `GET tasks/get/dropped/<id>/`, `tasks/get/surifile/<id>/` | ✅ | no |
| `[taskselfextracted]` | `GET tasks/get/selfextracted/<id>/[/<tool>/]` | ❌ | no |
| `[tasksurifile]` | (alias `taskdropped`) | ✅ | no |
| `[mitmdump]` | `GET tasks/get/mitmdump/<id>/` | ❌ | no |
| `[taskprocmemory]` | `GET tasks/get/procmemory/<id>/[/<pid>/]` | ✅ | no |
| `[taskfullmemory]` | `GET tasks/get/fullmemory/<id>/` | ❌ | no |
| `[payloadfiles]` | `GET tasks/get/payloadfiles/<id>/` | ✅ | no |
| `[procdumpfiles]` | `GET tasks/get/procdumpfiles/<id>/` | ❌ | no |
| `[machinelist]` | `GET machines/list/` | ❌ | no |
| `[machineview]` | `GET machines/view/<name>/` | ❌ | no |
| `[cuckoostatus]` | `GET cuckoo/status/` | ❌ | no |
| `[list_exitnodes]` | `GET exitnodes/` | ❌ | no |
| `[tasks_latest]` | `GET tasks/get/latests/<hours>/` | ❌ | no |
| `[task_x_hours]` | `GET tasks/stats/` | ❌ | no |
| `[statistics]` | `GET tasks/statistics/<days>/` | ❌ | no |
| `[yara_uploader]` | `POST yara_uploader/` | ❌ | no |

> **想要 `cuckoo/status/`、`machines/list/` 这些目前 ❌ 的对外通**：
> `sudo crudini --set /opt/cape-deploy/CAPEv2/conf/api.conf cuckoostatus enabled yes`
> `sudo crudini --set /opt/cape-deploy/CAPEv2/conf/api.conf machinelist enabled yes`
> `sudo systemctl restart cape-web`

---

## 6. 端点详表

### 6.1 提交任务（写入）

#### 6.1.1 `POST /apiv2/tasks/create/file/` —— 上传文件创建任务

| | |
|---|---|
| 启用 | ✅ (`[filecreate] enabled = yes`) |
| auth_only | no |
| rate | 1/s, 2/m |
| Content-Type | `multipart/form-data` |

**multipart 字段**：

| 名 | 必需 | 类型 | 说明 |
|---|---|---|---|
| `file` | ✅ | file | 单文件；如 `multifile=yes` 可多个（当前部署 `multifile=no`） |
| `package` | | str | 强制分析包，如 `exe` `dll` `pdf` `js` `doc` `xls` |
| `timeout` | | int | 分析超时（秒） |
| `priority` | | int | 1=low/2=med/3=high |
| `options` | | str | `key=value,key2=v2` 形式 |
| `machine` | | str | 指定机器 label；`all` 需 `[filecreate] allmachines=yes` |
| `platform` | | str | `windows` / `linux` / `darwin` |
| `tags` | | str | 逗号分隔，匹配机器 tags（如 `win10,x64`） |
| `custom` | | str | 自定义字段，出现在报告 `info.custom` |
| `memory` | | bool | `True` → 拍 VM full memory dump |
| `clock` | | str | 虚机伪造时间，格式 `MM-DD-YYYY hh:mm:ss` |
| `enforce_timeout` | | bool | `True` → 即使样本自行 exit 也跑满 timeout |
| `unique` | | bool | `True` 且同 hash 已在 pending/running → 不再建 task |
| `pcap` | | bool | `True` → 当作 PCAP 重放（不是普通分析） |
| `static` | | bool | `True` → 只做静态分析（不进 VM） |
| `route` | | str | 出网路由：`inetsim`/`tor`/`vpn`/`internet`/`drop` |
| `tlp` | | str | `red`/`amber`/`green`/`white`/`clear` |

**成功响应**：
```json
{
  "error": false,
  "data": {
    "message": "Task ID(s) [42] has been submitted",
    "task_ids": [42]
  },
  "url": ["http://example.tld/submit/status/42/"]
}
```

**失败情况**：
- `{"error":true,"error_value":"No file was submitted"}` —— 没传 `file`
- `{"error":true,"error_value":"Machine 'X' does not exist. Available: cuckoo1, cuckoo2"}`
- `{"error":true,"error_value":"File Create API is Disabled"}`（如 `enabled=no`）

---

#### 6.1.2 `POST /apiv2/tasks/create/url/` —— URL 任务

| | |
|---|---|
| 启用 | ✅ (`[urlcreate]`) |
| Content-Type | `application/x-www-form-urlencoded` |

| 字段 | 必需 | 说明 |
|---|---|---|
| `url` | ✅ | 待分析 URL（可逗号分隔多个，由 `[general] url_splitter` 控制分隔符） |
| 其余 | | 同 `tasks_create_file` 的 package/timeout/priority/.../tlp |

```bash
curl -X POST http://192.168.1.6:8090/apiv2/tasks/create/url/ \
  -d "url=http://malicious.example.com/exploit.html" -d "timeout=120"
```

---

#### 6.1.3 `POST /apiv2/tasks/create/static/` —— 仅静态分析

| | |
|---|---|
| 启用 | ✅ (`[staticextraction]`) |
| Content-Type | `multipart/form-data` |

| 字段 | 必需 | 说明 |
|---|---|---|
| `file` | ✅ | 文件 |
| `options` | | 同上 |
| `priority` | | 同上 |

不进 VM，只跑 unpacker / config extractor / yara 规则。

---

#### 6.1.4 `POST /apiv2/tasks/create/dlnexec/` —— 服务器主动下载 + 分析 ❌

| | |
|---|---|
| 启用 | ❌ (`[dlnexeccreate] enabled = no`) |

| 字段 | 必需 | 说明 |
|---|---|---|
| `dlnexec` | ✅ | 远端 URL，CAPE 后端下载后当文件分析 |
| `machine` | | 同上 |
| `options/timeout/priority/...` | | 同上 |

⚠️ 风险：滥用可让 CAPE 后端发起任意 HTTP 请求（SSRF）。

---

#### 6.1.5 `POST /apiv2/tasks/create/download_services/` —— 从第三方服务拉样本 ❌

| | |
|---|---|
| 启用 | ❌ (`[downloading_services] enabled = no`) |

| 字段 | 必需 | 说明 |
|---|---|---|
| `hashes` | ✅ | 逗号分隔的 sha256 或 sha1 list |
| `machine`/`options`/`custom` | | 同上 |

后端会用 VT/MWDB/MalwareBazaar 等第三方 API（需在 `conf/integrations.conf` 配 API key）拉文件再交任务。

---

#### 6.1.6 `POST /apiv2/tasks/delete_many/` —— 批量删任务

| | |
|---|---|
| 启用 | ❌（依赖 `[taskdelete]`） |

| 字段 | 必需 | 说明 |
|---|---|---|
| `ids` | ✅ | 任务 ID list（JSON 数组字符串或逗号分隔） |
| `delete_mongo` | | `True` 同时删 MongoDB 中的报告 |

---

### 6.2 任务生命周期管理

| Method | Path | api.conf | 当前 | 说明 |
|---|---|---|---|---|
| GET | `/tasks/reschedule/<task_id>/` | `[taskresched]` | ❌ | 把 task 状态重置为 pending 重跑 |
| GET | `/tasks/reprocess/<task_id>/` | `[taskreprocess]` | ❌ | 已 reported 的 task 重新过 processing/reporting 模块 |
| GET | `/tasks/delete/<task_id>/` | `[taskdelete]` | ❌ | 单删；`task_id` 可是 `5` / `5,6,7` / `5-9` |
| GET | `/tasks/delete/<task_id>/<status>/` | `[taskdelete]` | ❌ | 只删指定 status 的 task |
| GET | `/tasks/status/<task_id>/` | `[taskstatus]` | ✅ | 轮询状态 |

`tasks/status` 响应：
```json
{
  "error": false,
  "data": "pending"        // or "running", "completed", "reported", "failed_analysis", "failed_processing", "failed_reporting"
}
```

---

### 6.3 任务搜索 / 列表

#### `GET /apiv2/tasks/list/[<limit>/[<offset>/[<window>/]]]`

| | |
|---|---|
| 启用 | ✅ (`[tasklist]`) |
| 限制 | `maxlimit=50`、`maxwindow=1440 min`（24h）、`defaultlimit=10` |

URL path 段参数：
- `limit`（可选）：返回数量上限
- `offset`（可选）：偏移
- `window`（可选）：只列出最近 N 分钟创建的任务

响应：
```json
{
  "error": false,
  "data": [
    {"id":42, "status":"reported", "target":"sample.exe", "added_on":"2026-05-15 ..."},
    ...
  ]
}
```

#### `GET /apiv2/tasks/search/{md5|sha1|sha256}/<hash>/`

按文件 hash 反查 task IDs。响应：`{"error":false,"data":[{"id":42,...}, ...]}`

#### `POST /apiv2/tasks/extendedsearch/`

| | |
|---|---|
| 启用 | ✅ (`[extendedtasksearch]`) |
| Content-Type | `application/json` 或 form |

| 字段 | 说明 |
|---|---|
| `option` | 搜索维度：`malfamily`/`detection`/`yarah`/`name`/`type`/`comment`/`ip`/`domain`/`url`/`signature` 等（与 Web UI 搜索栏一致） |
| `argument` | 搜索关键词 |
| `search_limit` | 上限 |
| `lean` | `True` 只返回精简字段 |

---

### 6.4 任务结果下载

> 全部 GET，按 `task_id` 取结果。除 `[capeconfig]` 强制 auth_only=yes 外，其余只看全局 token 开关。

| Path | api.conf | 当前 | 返回 |
|---|---|---|---|
| `/tasks/view/<id>/` | `[taskview]` | ✅ | JSON：task 元数据 + machine info + errors |
| `/tasks/get/report/<id>/` | `[taskreport]` | ✅ | JSON 报告（默认 `json` format） |
| `/tasks/get/report/<id>/<fmt>/` | 同 | ✅ | `fmt` ∈ `json`/`html`/`pdf`/`maec`/`stix`（取决于已开启 reporter） |
| `/tasks/get/report/<id>/<fmt>/<zip>/` | 同 | ✅ | `zip` ∈ `yes`/`no`；启用时返回 zip 包 |
| `/tasks/get/iocs/<id>/` | `[taskiocs]` | ✅ | 简版 IOC JSON |
| `/tasks/get/iocs/<id>/detailed/` | 同 | ✅ | 完整 IOC JSON |
| `/tasks/get/config/<id>/` | `[capeconfig]` | ✅🔒 | CAPE config extractor 提取出的 family config JSON；**强制 token** |
| `/tasks/get/config/<id>/<cape_name>/` | 同 | ✅🔒 | 指定 family 名（如 `Emotet`） |
| `/tasks/get/screenshot/<id>/` | `[taskscreenshot]` | ✅ | 全部截屏 tar.gz |
| `/tasks/get/screenshot/<id>/<n>/` | 同 | ✅ | 单张截屏（n 为序号 0-9999） PNG |
| `/tasks/get/pcap/<id>/` | `[taskpcap]` | ✅ | PCAP binary |
| `/tasks/get/pcap/<id>/<variant>/` | `[taskpcap]` | ✅ | `variant` ∈ `decrypted`/`mixed`/`sslproxy` |
| `/tasks/get/tlspcap/<id>/` | `[tasktlspcap]` | ✅ | TLS-decrypted PCAP |
| `/tasks/get/keys/<id>/<kind>/` | `[tasktlskeys]` | ✅ | `kind` ∈ `tls`/`ssl`/`master` —— TLS 密钥导出 |
| `/tasks/get/etw/<id>/<kind>/` | `[tasketw]` | ✅ | `kind` ∈ `dns`/`network`/`wmi` —— ETW 流（NDJSON） |
| `/tasks/get/evtx/<id>/` | `[taskevtx]` | ✅ | EVTX 事件日志 |
| `/tasks/get/dropped/<id>/` | `[taskdropped]` | ✅ | dropped files zip（可选 query string `?max_size=N`） |
| `/tasks/get/surifile/<id>/` | `[taskdropped]` | ✅ | Suricata 提取出的文件 zip |
| `/tasks/get/selfextracted/<id>/[/<tool>/]` | `[taskselfextracted]` | ❌ | unpacker 自解压样本 |
| `/tasks/get/payloadfiles/<id>/` | `[payloadfiles]` | ✅ | CAPE 内存提取出的二级 payload zip |
| `/tasks/get/procdumpfiles/<id>/` | `[procdumpfiles]` | ❌ | process dump files |
| `/tasks/get/procmemory/<id>/[/<pid>/]` | `[taskprocmemory]` | ✅ | 进程内存 dump（pid 全或单） |
| `/tasks/get/fullmemory/<id>/` | `[taskfullmemory]` | ❌ | 全 VM 内存快照（大！） |
| `/tasks/get/bulkzip/<id>/<folder>/` | `[taskbulkzip]` | ✅ | `folder` 白名单：`logs`/`network`/`memory`/`selfextracted` |
| `/tasks/get/mitmdump/<id>/` | `[mitmdump]` | ❌ | mitmproxy HAR |
| `POST /tasks/get/stream/<id>/` | `[taskstatus]` | ✅ | 从正在跑的 VM 流式拉文件 |

`POST /tasks/get/stream/<task_id>/` body 字段：

| 字段 | 必需 | 说明 |
|---|---|---|
| `filepath` | ✅ | guest 内绝对路径 |
| `is_local` | | `True` 表示 filepath 是 host 上而非 guest |

---

### 6.5 文件 / 样本查询

| Path | api.conf | 当前 | 说明 |
|---|---|---|---|
| `GET /files/view/md5/<md5>/` | `[fileview]` | ✅ | 按 hash 查样本元数据（sha256 / size / type / file_type） |
| `GET /files/view/sha1/<sha1>/` | 同 | ✅ | 同 |
| `GET /files/view/sha256/<sha256>/` | 同 | ✅ | 同 |
| `GET /files/view/id/<sample_id>/` | 同 | ✅ | 按 DB id 查 |
| `GET /files/get/md5/<v>/` | `[sampledl]` | ❌ | 下载原始样本（dangerous） |
| `GET /files/get/sha1/<v>/` | 同 | ❌ | 同 |
| `GET /files/get/sha256/<v>/` | 同 | ❌ | 同 |
| `GET /files/get/task/<task_id>/` | 同 | ❌ | 按 task id 下样本 |

`files/get` 支持 `?encrypted=1` query string → 返回 zip-encrypted with password "infected"。

---

### 6.6 系统 / 机器信息

| Path | api.conf | 当前 | 说明 |
|---|---|---|---|
| `GET /machines/list/` | `[machinelist]` | ❌ | 返回所有 KVM machines 列表 |
| `GET /machines/view/<name>/` | `[machineview]` | ❌ | 单机详情（label / platform / tags / locked） |
| `GET /cuckoo/status/` | `[cuckoostatus]` | ❌ | CAPE 主服务状态（version / tasks counts / cpu 等） |
| `GET /exitnodes/` | `[list_exitnodes]` | ❌ | 列出 routing exitnodes |
| `GET /tasks/get/latests/<hours>/` | `[tasks_latest]` | ❌ | 最近 N 小时 task IDs |
| `GET /tasks/stats/` | `[task_x_hours]` | ❌ | 24h 每小时 task 统计 |
| `GET /tasks/statistics/<days>/` | `[statistics]` | ❌ | N 天范围的 processing/reporting time 统计 |

---

### 6.7 其它

| Path | api.conf | 当前 | 说明 |
|---|---|---|---|
| `GET /` | — | ✅ | API 帮助 HTML 页（人浏览用） |
| `POST /api-token-auth/` | — | ✅ | 标准 DRF 取 token（`username`/`password`，只在 token_auth_enabled=yes 时有意义） |
| `POST /yara_uploader/` | `[yara_uploader]` | ❌ | 上传自定义 yara 规则；`category` 字段决定路径 |

---

## 7. token 认证开启步骤（如需）

> 本部署当前 `token_auth_enabled = no`，**0.0.0.0:8090 全部 endpoint 任意网络可达者都能调**。如你的网络非完全可信，建议至少做下面一组操作之一：
>
> **(a) 关闭外网监听**（最小代价）：`sed -i 's|0.0.0.0:8090|127.0.0.1:8090|' /lib/systemd/system/cape-web.service && systemctl daemon-reload && systemctl restart cape-web` —— 外部就到不了。同机服务正常调。
>
> **(b) 开 token 认证**：
>
> ```bash
> # 1. 开总开关
> sudo crudini --set /opt/cape-deploy/CAPEv2/conf/api.conf api token_auth_enabled yes
>
> # 2. 建 admin（如果还没有）
> sudo -u cape -H bash -c '
>   cd /opt/cape-deploy/CAPEv2/web
>   /etc/poetry/bin/poetry run python manage.py migrate --run-syncdb
>   DJANGO_SUPERUSER_USERNAME=admin \
>   DJANGO_SUPERUSER_EMAIL=admin@local \
>   DJANGO_SUPERUSER_PASSWORD=CHANGE_ME \
>     /etc/poetry/bin/poetry run python manage.py createsuperuser --noinput
> '
>
> # 3. 重启
> sudo systemctl restart cape-web
>
> # 4. 拿 token（http://192.168.1.6:8090/admin/authtoken/token/ 也能生成）
> curl -X POST http://192.168.1.6:8090/apiv2/api-token-auth/ \
>   -d "username=admin" -d "password=CHANGE_ME"
> # → {"token":"abcd...40hex"}
> ```

---

## 8. 附：常用 curl 示例

> 当前 token_auth_enabled=no，下例不带 `Authorization`。开了之后所有请求加 `-H "Authorization: Token <hex>"`。

### 提交本地文件分析

```bash
curl -X POST http://192.168.1.6:8090/apiv2/tasks/create/file/ \
  -F "file=@./sample.exe" \
  -F "package=exe" \
  -F "timeout=120" \
  -F "priority=2" \
  -F "tags=win10,x64"
# → {"error":false,"data":{"task_ids":[42],"message":"..."},"url":["..."]}
```

### 提交 URL 分析

```bash
curl -X POST http://192.168.1.6:8090/apiv2/tasks/create/url/ \
  -d "url=http://malicious.example.com" \
  -d "timeout=120" \
  -d "route=inetsim"
```

### 轮询状态

```bash
curl http://192.168.1.6:8090/apiv2/tasks/status/42/
# → {"error":false,"data":"running"}
```

### 取完整 JSON 报告

```bash
curl http://192.168.1.6:8090/apiv2/tasks/get/report/42/json/ -o report-42.json
```

### 取 PCAP

```bash
curl http://192.168.1.6:8090/apiv2/tasks/get/pcap/42/ -o task-42.pcap
```

### 取截屏（zip 包）

```bash
curl http://192.168.1.6:8090/apiv2/tasks/get/screenshot/42/ -o screenshots-42.tar.gz
```

### 按 sha256 反查 task

```bash
curl http://192.168.1.6:8090/apiv2/tasks/search/sha256/abc...123/
# → {"error":false,"data":[{"id":42,...}]}
```

### Extended search by detection

```bash
curl -X POST http://192.168.1.6:8090/apiv2/tasks/extendedsearch/ \
  -H "Content-Type: application/json" \
  -d '{"option":"detection","argument":"Emotet","search_limit":50}'
```

### 列出最近任务

```bash
curl 'http://192.168.1.6:8090/apiv2/tasks/list/20/0/'      # 最新 20 条
curl 'http://192.168.1.6:8090/apiv2/tasks/list/50/0/60/'   # 最近 60 分钟创建的
```

### 取 CAPE family config（强制 token，即使全局 token_auth_enabled=no）

```bash
curl -H "Authorization: Token YOUR_TOKEN" \
     http://192.168.1.6:8090/apiv2/tasks/get/config/42/
```

---

## 9. 参考

- 上游路由：`web/apiv2/urls.py`（CAPEv2 commit `dd36c30`）
- 上游 views.py：`web/apiv2/views.py`
- 上游配置文档：[CAPEv2 API docs](https://capev2.readthedocs.io/en/latest/usage/api.html)（部分字段过期，以本文档为准）
- DRF token auth：https://www.django-rest-framework.org/api-guide/authentication/#tokenauthentication
