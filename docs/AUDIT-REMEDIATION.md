# 审计整改与验收记录

整改基线：`v1.2.7` / `1e2222db2d2a9f0040ccf9ad7913ce21742203d2`。依据用户提供的《04-复核勘误与整改清单》和《03-Mihomo-Manager-审计与整改建议》，冲突按 04 的复核结论处理。历史审计原文与证据未改动。

本文记录本地整改及隔离验收。修复完成后版本提升到 `v1.3.0`：`VERSION`、bootstrap 的 `PROJECT_VERSION`/`PACKAGE_NAME`、`mm.sh`/`mtp.sh` 的 `SCRIPT_VERSION` 与测试夹具已同步。发布时必须把 bundle、bootstrap 和摘要作为同一套资产一起上传，否则新入口会拒绝旧包。

## 整改对照

| 编号 | 实施内容 | 回归证据 |
|---|---|---|
| MM-01 | 临时订阅使用独立私有目录与发布根；发布根只含当前随机 token 对应内容；升级停止旧 HTTP/隧道并轮换临时 token；发布目录位于 root 控制的父目录。 | audit-sub：31 组通过，含旧/私有路径拒绝、迁移幂等、发布失败回退和无关监听器存活。 |
| MM-02 | 通用防火墙放行命令拒绝受 SOCKS5 白名单保护的端口；启动前建立策略，规则失败关闭入口；恢复策略并处理 IPv4/IPv6。 | audit-cli：15 项通过；audit-service：149 项通过，含策略建立失败、双栈回退和受保护端口拒绝通用放行。 |
| MM-03 | Mihomo 使用独立用户及专用可写 data 目录；管理代码、节点表、密钥表和设置保持 root 私有；仅配置与证书提供必要只读权限。 | audit-service：149 项通过，含 14 项真实 DAC 检查；nobody 可读配置/证书并写 data，不能读写控制数据、脚本或移动发布根。 |
| MM-04 | 锁与回滚绑定 BASHPID；子进程只关闭继承描述符，不解父锁；每次变更使用确切快照，显式传播生成、发布和 readiness 失败；拒绝嵌套事务。 | audit-storage：270 项通过；包含并发锁、故障注入与 ins/rep/delete/restart/restore 回滚。 |
| MM-05 | CLI 有值参数与端口严格校验；password 正确映射 passwd；WS CDN SNI 正确传递。 | audit-cli：15 项通过；audit-interface：25 项通过。 |
| MM-06 | 候选发布必须通过完整版本、文件清单、模式、语法与摘要校验；升级统一事务处理代码、mtp、watchdog、unit 和状态；卸载持有目录外稳定锁，按实例停止进程并保留独立资源。 | audit-install：17 项通过，含升级失败及 watchdog stop/disable/daemon-reload 故障回退；audit-release：44 项通过。 |
| MM-07 | 客户端区分 read token 和每机 report token，仅允许 HTTPS；拒绝旧共享 token 与凭据复用；接口和迁移说明同步。 | audit-sub：31 组通过；外部 Worker 服务端权限矩阵不在本仓库，不能视为已修复。 |
| MM-08 | Ookla 使用 --format=json，bytes/s × 8 / 1000000；超时和 argv 严格处理，已知架构缺摘要时在下载前拒绝；默认不在非交互或持全局锁期间测速。 | audit-speedtest：32 项通过；真实二进制仅检查版本和帮助，没有执行公网测速。 |
| MM-09 | 统一 bootstrap、bundle manifest、仓库 sidecar 和 CI 的一致性门禁，构建规范化可复现发布包。 | audit-release：44 项通过；最终 build --refresh 与 check-version 均通过，bootstrap pin、sidecar 与 bundle 完全配套。 |
| MM-10 | 删除无效 run 子命令；测试替身拒绝无效命令行；真实内核验证指定配置确实加载。 | 固定 Mihomo v1.19.31 真实内核验收通过。 |
| MM-11 | 校验与启动共同使用显式 -d、指定 config.yaml 与 SAFE_PATHS；专用 data 目录与 root 配置/证书分离。 | 真实内核 9 监听器验收及 audit-service 中 14 项 DAC 检查通过。 |
| MM-12 | ss 使用本地地址第 5 列，netstat 保留第 4 列；锁内更新端口缓存并再次校验。 | audit-network：14 组通过，含真实 IPv4/IPv6 TCP/UDP loopback socket。 |
| MM-13 | YAML 标量使用 JSON 安全编码；元数据 25 字段采用 NUL 分隔和完整性标记；保留控制字符与空字段；HY2 显式 0 保留，双 0 使用 BBR。 | audit-render：34 项通过；真实内核特殊字符、双 0/混合带宽和 25 字段保真验收通过。 |
| MM-14 | watchdog 初始化固定上游元数据，运行期不安装依赖或下载；失锁立即退出；检查实例 PID 身份并等待停止，再执行恢复。 | audit-service：149 项通过，含失锁零副作用、依赖与脚本不变、PID 身份/出生时间、延迟 exec 和 PID 保存失败候选清理。 |
| MM-15 | 初始化/对账前同时校验节点与密钥表；损坏或单表丢失时停止写入；显式恢复允许隔离坏状态并按原始字节回退，保留缺失/存在状态与完整证书集。 | audit-storage：270 项通过，含 NUL 原字节、损坏表、发布第三文件失败与恢复失败保留证据。 |
| MM-16 | MTProxy 校验 32 位 hex secret 和域名，直接 argv 启动，验证 exe/argv/starttime 后停止；私有原子配置，兼容既有启动方式迁移。 | audit-mtp：50 项通过，含真实 amd64 mtg 的 IPv4/IPv6/双栈监听与有界停止。 |
| MM-17 | 普通增节点只应用明确提供的订阅设置；省略模式保留 Worker 模式、域名及 read/report token；临时域名使用独立字段。 | audit-storage 自动安装/替换与 Worker 保持用例、audit-sub 31 组及 305 项功能冒烟通过。 |
| MM-18 | 更正菜单 8 调优/10 卸载；doctor 调用统一校验器；前端禁用字段不输出，DNS 语义与后端一致，移除无效 0-RTT 控件，外链补 rel 属性并重建 Worker。 | audit-interface：25 项通过，含 Node 语法与重建 Worker 一致性；audit-cli：15 项通过。 |

额外边界修复覆盖严格 IP/保留地址过滤、证书 SAN/单级通配符及证书私钥匹配、证书导入失败原子性、清理函数错误传播、多 short_id 链接选择、日志符号链接拒绝和 copytruncate 轮转。未将审计中的推测当作已确认故障：保留 systemd 保护选项，不依据 ProcSubset 单独推导 UDP 必然失效；历史 Release 的原包/清单一致，原问题是仓库 sidecar 漂移。

## 验证环境与方法

Linux 验证在 WSL Debian 13 的原生 home 工作目录中进行；源码仅同步进入独立验收目录。测试使用临时状态、隔离锁、loopback 监听和受控命令替身，没有安装本机生产服务、调整本机防火墙或 sysctl，也没有提交、推送或部署。获取 GitHub 内容仅使用普通 Git 或已知 Release 下载地址，没有调用 GitHub REST/GraphQL API。

真实核心为固定 Mihomo Meta v1.19.31 linux/amd64，压缩资产 SHA256：

```text
d5e74bbddbdfff49a1aef7775bf5911da59f0d7196ed509a0ac914b3653dd5f1
```

accept-mihomo 验收 9 个真实 TCP/UDP 监听器、IPv4/IPv6 SOCKS 认证协商、Argo loopback、HY2 双 0/混合带宽、控制字符和 25 字段元数据，并确认禁用 API/DNS 后没有额外监听器。功能冒烟共 305 项通过；其服务生命周期使用替身，真实服务权限与模板由独立专项覆盖。

## 初轮完整集成门禁

2026-11-21 在同一冻结源码快照执行 18 个集成阶段，全部通过；额外以 root 启动隔离 DAC 专项，同样通过。构建前对源码摘要逐项复核，验证期间没有源码漂移。完整结果见 [阶段汇总](../verification/summary.txt)，原始日志与源码摘要位于 [verification](../verification/)。故障注入日志中的预期错误不代表测试失败，应以各项断言和最终退出码为准。

| 检查 | 结果 | 记录 |
|---|---|---|
| Bash 语法 / ShellCheck warning 门禁 | 40 个 shell 文件语法通过；指定入口、模块、发布与专项脚本 ShellCheck 通过 | [syntax](../verification/syntax.log)、[shellcheck](../verification/shellcheck.log) |
| 存储事务 | 270 项，0 失败 | [audit-storage](../verification/audit-storage.log) |
| 网络 / 证书 / 链接 | 14 组，0 失败 | [audit-network](../verification/audit-network.log) |
| 测速 / 调优 | 32 项，0 失败 | [audit-speedtest](../verification/audit-speedtest.log) |
| MTProxy | 50 项，0 失败；含真实 mtg IPv4/IPv6/双栈 | [audit-mtp](../verification/audit-mtp.log) |
| 发布候选 | 44 项，0 失败 | [audit-release](../verification/audit-release.log) |
| 渲染 | 34 项，0 失败 | [audit-render](../verification/audit-render.log) |
| CLI / 前端 | 15 / 25 项，0 失败 | [audit-cli](../verification/audit-cli.log)、[audit-interface](../verification/audit-interface.log) |
| 安装 / 升级 / 卸载 | 17 项，0 失败 | [audit-install](../verification/audit-install.log) |
| 订阅 | 31 组，0 失败 | [audit-sub](../verification/audit-sub.log) |
| 服务 / watchdog | 普通运行 135 项；追加 14 项 DAC 后为 149 项，0 失败（两次结果不叠加计数） | [audit-service](../verification/audit-service.log)、[audit-service-dac](../verification/audit-service-dac.log) |
| 功能冒烟 | 305 项，0 失败 | [smoke](../verification/smoke.log) |
| 真实 Mihomo | 9 个监听器与配置验收通过 | [accept-mihomo](../verification/accept-mihomo.log) |
| 构建 / 发布一致性 | refresh 与 tag 检查通过；连续两次构建摘要相同 | [build-release](../verification/build-release.log)、[check-version](../verification/check-version.log) |

## 目标主机实测补充

初轮门禁后，又在用户提供的 32 台主机上执行隔离回归与真实核心 loopback 验收。逐机原始阶段、后续复验、跳过项、软件包准备副作用与最终结论统一见 [主机测试报告](../verification/remote-20261121/REPORT.md)；不能把初轮失败、后续修复验证和最新源码复验合并成一个无条件通过数。完整主机复验快照（`973490a52e749325…`）为 27 台通过、5 台需复核；随后发现并修复 jq 1.6 编码问题，另做 32 台定向补验：28 台通过，4 台因 SSH/SFTP 中断缺少完整证据；Kulai 与 PHX 两台完整冒烟补验均为 304 项通过、0 项失败，并各明确跳过 2 项需编译器的断言。补验单独记录，未将其冒充最终交付版的全量逐机复跑。

实测推动的补充修改包括：GNU tar 版本输出先完整捕获再判断，避免 pipefail 下 grep -q 提前退出导致误报；旧版 OpenSSL 即使域名不匹配也可能退出 0，因此必须同时检查明确的匹配结论；Python HTTP 后备实现使用同步请求与 5 秒 socket 空闲超时，避免旧 glibc 在 chroot 后取消线程时加载 libgcc_s 失败；darkhttpd 补上 no-store 响应头，并按有效的 text/plain 媒体类型验证。jq 1.6 的批量 URI 编码调用改为先放过滤表达式、再用 `--` 分隔用户字段，修复旧版 jq 静默产生空 SNI/Host/path 的问题，并测试以横杠开头的字段。测试夹具的非 TTY 确认改为完整捕获输出，避免无须读取 stdin 的函数使上游 echo 收到 SIGPIPE。测试夹具同时适配既有 nobody 主组、低内存 TCP 缓冲上限、ash exec 优化与 BusyBox 工具差异，保留权限、进程身份和拒绝路径断言。

受影响模块另在原生 WSL Linux 复验：发布 47 项、网络 15 组、服务 135 项、MTP 50 项、冒烟 306 项、订阅 37 组均通过，另一次实际降权 DAC 验证为 149 项通过。记录以 `remote-update-` 为前缀，逐机实测只在独立工作目录执行。公网 NAT 连通、完整代理协议端到端握手和生产 init 集成未据此宣称通过；缺少编译器和超时仍明确列为跳过或未通过。

复验命令：

```bash
bash scripts/build-release-bundle.sh --refresh
bash scripts/check-version.sh --tag v1.3.0
```

最终运行包为 `dist/mihomo-manager-v1.3.0.tar.gz`，SHA256：

```text
e885d38c18adbbc471122ed4192ae2749586b92a945692b79edd07a332e321a5
```

配套 bootstrap `install.sh` 的 SHA256 为 `e0df4858d3f7fe7e7ab33e649f79ac6625939a5fa073669ead60679ee4f1b595`；sidecar `install.sh.sha256` 为 `d8f376651787fb7364c801a36453b580f2e3322b996591a67b8dbe0b9b5ce7ca`，与之匹配；`dist/checksums.txt` 为 `821bb4726a65d2c7b01efe023a99789df49652c987f9b4e1f1c2a2f2ffca1de8`。`dist/` 按仓库约定不入版本库，发布时以 tag `v1.3.0` 上传上述资产。运行包只含安装所需文件。

## 真实主机迁移与端到端验收

在隔离回归之外，另按用户提供的两份主机清单（27 台 Oracle 类 + 5 台 Dandan/AWS/StormHost/Firadio，共 32 台）做了真实替换：每台先备份既有 Xray-Manager 的路径、单元定义、启用状态、root crontab 与共享 `/usr/local/bin/mtp`，再停用并隔离旧服务，然后用离线安装包部署本仓库版本并按清单创建节点。结果是 **31 / 32 台**迁移并在真实客户端通过，**53 个节点**全部通过双目标验收；US-Oracle-SJC-nat 未迁移。逐机结果、节点清单、覆盖统计与复现方法保存在本地证据目录 `verification/live-20261121/`（含主机清单与日志，按约定不随仓库发布）。

迁移方法与边界：

- 旧管理器一律不使用其自带卸载脚本（Xray 的卸载会删除共享 `/usr/local/bin/mtp`、`tuic-server`、`hysteria`）。改为先证明进程归属（`/proc/<pid>/exe` + argv + 打开的文件描述符 + cwd）再停用；Argo 进程的 argv 不含旧路径，只能靠日志文件描述符识别。
- 停用顺序为：禁用 watchdog 定时器与服务 → 停用管理器单元（systemd 或 OpenRC）→ 停用数据面进程 → 隔离路径 → `daemon-reload` → 校验监听消失。备份成功前不做任何删除。
- 节点参数取自清单的 TCP/UDP 端口与协议要求；清单写“随机”的按空闲端口自选。
- 4 台主机（DE-Oracle-FRA-nat、US-Oracle-SJC-nat、MX-Oracle-nat、MY-Oracle-Kulai）清单无 UDP 转发，无法承载 TUIC，按既定替代方案改为首个 TCP 端口的 VLESS-Reality 并在报告中逐条注明；US-Oracle-SJC-nat 未迁移（见下）。
- JP-Oracle-TKY-nat 与 SGW-Oracle-nat 要求 TUIC，但主机侧 `tcpdump` 抓不到任何入站 UDP 包（客户端已发包、服务端 `ss` 显示正常监听），确认运营商不转发 UDP 后同样改为 VLESS-Reality，保留 Argo 节点。

本轮实测暴露并修复的四个缺陷：

1. **BusyBox 的 setpriv 不能降权**：Alpine 精简镜像里 `/bin/setpriv -> busybox`，只有能力位参数，`--reuid` 直接报 `unrecognized option`，服务永远无法以 `mihomo` 用户启动。现在先做功能探测，失败依次回退 `su-exec`、`su`，并按 UID/GID 数字参数传递；启动路径与配置校验路径共用同一套判定。
2. **父目录阻止服务用户穿越**：Alpine 的 `/usr/local/etc` 默认 `0700 root:root`，即使配置、证书、目录权限全对，服务用户也读不到 `config.yaml`（实测 26 台 Alpine 全部如此，Debian 默认 `0755` 无此问题）。现在部署时逐级检查 `BASE_DIR` 的祖先目录，只对缺少 other-execute 的目录补 `o+x` 并打印告警。
3. **低内存主机就绪等待过短**：128MB 的 BR-Oracle-nat 在负载高时冷启动 mihomo 超过默认等待，被判“数据面就绪失败”并回滚。默认重试次数改为按内存自适应（`MemTotal < 256MB` 时 30 次，否则 10 次），仍可用 `MM_READINESS_RETRIES` 覆盖。
4. **出网经代理时分享链接地址错误**：US-Firadio 的出网走 WARP，自动探测到的是 `104.28.195.192`（代理出口），不是入站可达地址，客户端连接必然超时。新增 `public_ip_pin`（`settings.json`，或环境变量 `MM_PUBLIC_IP` 临时覆盖）：固定值优先于自动探测与 TTL 缓存，且非法或私网地址直接拒绝而不是静默回退。

端到端验收使用真实 mihomo v1.19.31 作为客户端（不是模拟握手）：把每个节点的分享链接导入本地客户端，逐个节点请求 `https://www.gstatic.com/generate_204` 与 `https://api.ipify.org`，要求分别返回 204 与 200。并行跑客户端会在本机互相干扰、产生假超时，因此最终判定一律串行复核。

未完成项与限制：**US-Oracle-SJC-nat（`159.54.162.50:21035`）从测试端始终无法建立 SSH 连接**，该机保持原状、仍是 Xray-Manager，未做任何改动；临时 Argo 域名在每次重装/重建后都会更换，交付时附的是当前有效链接。
## 迁移注意事项

- Worker 服务端位于外部项目。必须在服务端实施只读、每机上报、管理员三类权限并撤销旧共享 token；本仓库客户端修改不能代替服务端授权。
- 升级会停止旧临时订阅入口并轮换临时访问 token。若旧根曾经可访问，应按实际暴露范围轮换节点凭据；工具无法判断历史访问与泄漏范围。
- 旧数据中缺失的 HY2 带宽与历史被默认化的 0 无法区分，需要用户对原本希望不限速的节点重新明确设置 0。
- 首次缺少核心时，先单独准备并提交系统依赖和有效核心，再开始节点事务；后续节点失败恢复到核心准备完成的状态，已安装的软件包、专用账户和核心二进制会保留。已有核心的准备与节点变更共同受本次状态快照保护。
- mkdir 锁降级模式在所有者身份记录不完整时保留锁目录并停止操作，避免自动误删仍有效的锁；需由维护者确认进程状态后恢复。
- 已在 31 台目标主机（覆盖 OpenRC 与 systemd、ARM64 与 AMD64、Oracle NAT 与直连主机）完成公网端到端验证，但未外推到其他发行版、内核或防火墙组合；换到新环境仍应先跑一遍 `tests/` 与真实客户端验收。
