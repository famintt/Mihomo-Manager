# 订阅模式、凭据与升级迁移

管理器支持临时 HTTP 隧道模式和固定 Worker 模式。本文说明本仓库实现的客户端行为；外部 Worker 服务端需要单独部署、审查和验收。

## 临时订阅与本地目录

`sub_mode=temp` 使用仅监听 `127.0.0.1` 的 HTTP 服务，再通过临时 Cloudflare Tunnel 提供访问地址。默认端口为 18080；临时域名可能随隧道重启变化。包含随机 token 的订阅 URL 本身就是读取凭据，不应公开分享。

以下位置均相对 `BASE_DIR`，由管理器控制，与 Mihomo 可写的 `data/` 目录分离：

| 位置 | 权限与用途 |
|---|---|
| `sub-private/` | 目录 0700；保存明文节点列表、base64 载荷、临时 token、订阅 URL，以及请求期间的私有 curl 配置和响应文件。普通私有文件为 0600。 |
| `sub-public/` | 目录 0755；成功发布后只保留当前 `<32位小写hex token>.txt`，文件 0644，内容为 base64 订阅。 |
| `sub-migration-v2` | 升级迁移完成标记，普通文件 0600，位于 `BASE_DIR` 本身。 |

Python HTTP 后备实现只允许当前 token 对应路径的 GET/HEAD，拒绝目录列表、固定私有文件名、额外路径、查询参数和路径穿越。读取载荷时拒绝符号链接；以 root 启动时先 chroot 到发布目录，再降权到 nobody。Python 使用同步 HTTPServer，避免旧版 glibc 在 chroot 后取消工作线程时无法加载 libgcc_s；每个已接受连接设置 5 秒 socket 空闲超时。该超时针对 socket 操作，不代表整个请求有 5 秒总期限。若已安装 darkhttpd，则使用其 chroot、禁止列表及降权选项。两个 HTTP 后端均返回 `Cache-Control: no-store` 和载荷长度；darkhttpd 对 `.txt` 使用 `text/plain`，Python 明确使用 `text/plain; charset=utf-8`。darkhttpd 会忽略有效 token 路径后的查询参数并返回同一公共载荷；其路径穿越及文件后追加路径可能分别返回 400、500，而 Python 返回 404。验收按后端检查具体拒绝状态与响应体，拒绝路径不得泄漏订阅载荷。启动检查进程身份，并在有限次数内确认本机读取成功。

节点列表或分享链接生成失败时，不替换此前已发布的公共载荷。发布根出现意外文件或符号链接时操作失败，避免跟随不受信任路径。发布采用临时文件与同一文件系统内重命名；这不意味着不同私有文件组成一个独立数据库事务。

## Worker 客户端合同

使用现有安装/更新流程的环境变量或持久设置配置：

| 设置 | 要求 |
|---|---|
| `sub=1` | 启用订阅功能。 |
| `sub_mode=worker` | 选择固定 Worker 模式；省略模式时保留已有设置，新安装默认为 temp。 |
| `sub_domain` | HTTPS origin 或裸 DNS 主机名；裸主机名补 HTTPS，可指定有效端口，允许一个末尾斜杠；不接受用户信息、路径、查询或片段。 |
| `sub_machine` | 可选，匹配 `[a-z0-9][a-z0-9_-]{0,63}`；缺省由管理器从 name 或主机名生成 slug。 |
| `sub_read_token` | 订阅读取凭据，只含 `[A-Za-z0-9_-]`，至少 22 字符。 |
| `sub_report_token` | 每机上报凭据，字符要求同上，与读取凭据和旧共享凭据均不同。 |

两类 token 应分别使用至少 128 位随机数生成。管理员凭据只留在 Worker 管理侧，不填入节点管理器。

客户端构造读取地址 `https://<origin>/sub/<machine>/<read-token>`，并向 `https://<origin>/api/v1/report/<machine>` POST base64 载荷，使用 `Authorization: Bearer <report-token>`。请求强制 HTTPS，不自动跟随重定向；携带上报凭据的 curl 配置文件为 0600，请求结束后清理。保存的订阅 URL 只包含读取凭据。请求失败会返回上报失败，不能当作远端发布成功。

旧 `sub_token` 不再作为读取或上报凭据的回退来源。缺失、格式错误、与旧凭据相同或 read/report 复用时失败关闭。旧版共用 TOKEN 的 Worker 必须先迁移，不能只升级客户端后继续使用共享管理员 token。

外部 Worker 必须自行落实并验收：读取凭据只能读取；每机上报凭据只能修改授权机器；管理员端点使用独立凭据；旧共享 token 已撤销。本仓库的离线客户端测试不证明远端权限矩阵、合并订阅路由、数据保留或实际部署已正确。

## 旧临时订阅迁移

升级协调器在持有全局锁、停止旧入口和看门狗后调用迁移，再启动新入口。迁移确认旧进程的可执行文件、完整 argv、日志描述符及进程出生标识，只停止能够确认归属的旧 HTTP/隧道进程。无关监听器不作为本实例进程终止。

旧 `BASE_DIR/sub/` 被清理，临时 token 轮换；旧 trycloudflare 域名移到 `sub_temp_domain`，自定义 Worker 域名保留。成功后原子写入迁移标记；已有普通非符号链接标记时重复调用不再次轮换。目录、设置或标记写入错误返回失败，不宣称迁移完成。迁移失败应由升级事务回滚并保留诊断信息。

若旧公开根曾被访问，应按实际暴露范围轮换节点凭据。工具无法回溯判断历史泄漏。

## 操作与验证

使用 `mm sub url` 查看或生成读取地址，`mm sub status` 查看状态，`mm sub stop` 停止本地订阅入口。Worker 模式的 URL 生成仅校验客户端配置，不代表远端已可用或已接受上报。

运行 `bash tests/audit-sub.sh` 执行隔离回归。测试使用临时目录、loopback 监听和本地 curl 替身，不请求外部 Worker、不修改主机防火墙或生产服务。

## 遗留共享 Token Worker 的实际处置

审计后的客户端**不会**复用旧版共用 TOKEN 上报（见上文“失败关闭”），这是有意的安全修复，不是缺陷。因此把一批旧 Xray-Manager / Singbox-Manager 主机迁到本管理器后，旧 Worker 中保存的仍是迁移前上报的节点：读取地址照常返回 200 和一大堆节点，但对应服务已经停止，客户端逐条测速全部得到 `-1`。这是“订阅拉得到、节点全失效”的典型成因。

处置顺序：

1. **推荐**：由 Worker 管理侧为每台机器签发独立的读取/上报凭据，再用 `sub_domain` / `sub_machine` / `sub_read_token` / `sub_report_token` 配置到各机，之后 `mm sub start` 正常上报。
2. **过渡**：迁移窗口内用管理器之外的临时脚本，按机器向 `https://<origin>/api/v1/report/<machine>` POST 本机当前节点列表的 base64 文本，Authorization 用旧共享 token，把每台机器的记录刷新为本机现有节点；不再需要的机器上报空载荷（`nodes=0`）以清除失效条目。此做法只是过渡，不改变管理器的失败关闭行为，也不应写进安装脚本。
3. 刷新后必须用真实客户端复验：读取地址返回 base64，解码后逐节点走 `generate_204` 与 `api.ipify.org`。

两点实测注意：

- 请求 `/api/v1/report/` 时 Cloudflare 会按 User-Agent 拦截：`Python-urllib` 直接 403，需带 `curl/8.x` 一类普通 UA。
- 机器标识是**小写** slug（例如 `phx-amd`、`jp-oracle-tky-nat`）；大小写不符的读取路径返回 400。

