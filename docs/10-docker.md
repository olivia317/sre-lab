# V2.0：Flask 容器化、镜像发布与部署回退

> 更新日期：2026-10-14。本文描述截至当日实际验证的结果；“已配置”“已验证”和“待验证”分别记录，不将计划视为完成。

## 1. 目标与当前进度

将 Flask + Gunicorn 应用容器化，通过 Docker Compose 管理运行配置，接入现有业务入口、数据库、监控和日志系统，并逐步实现可追溯的镜像发布和部署回退。

| 能力 | 当前状态 | 验证范围 |
| --- | --- | --- |
| Docker 镜像构建与 Compose 管理 | 已完成 | 应用启动、资源限制和运行参数 |
| 容器访问宿主机 MariaDB | 已完成 | 数据库读取及正常路径 CRUD |
| Nginx 切换到容器应用 | 已完成 | 本机与公网入口验证 |
| 容器指标与日志采集 | 已完成 | Prometheus 抓取、Alloy → Loki 日志查询 |
| 重启策略与健康检查 | 已完成 | 主进程退出后的自动重启演练 |
| Docker 日志轮转 | 已配置并核对参数 | 尚未通过写满日志验证实际轮转 |
| GitHub Actions CI | 已完成 | 自动构建、状态接口和指标接口冒烟测试 |
| GHCR 镜像发布 | 已完成 | 测试通过后发布同一个镜像 |
| GHCR 镜像手动部署 | 已完成 | 临时容器验证、正式切换、业务及可观测性验收 |
| 部署准备与执行脚本 | 已实现并部分验证 | 同镜像执行、跨镜像切换成功；健康检查失败后的配置自动回退成功 |
| 跨镜像版本切换与回退 | 成功切换已验证；失败回退待验证 | 已从 52f765b 对应镜像切换至 0f97933 对应镜像 |
| GitHub Actions 触发服务器部署 | 尚未实现 | 当前脚本由人工在服务器启动 |

当前已实现 CI 和镜像发布，以及服务器侧部署脚本；尚未打通由 GitHub Actions 调用服务器部署脚本的流程。

## 2. 当前部署架构

正式请求路径：公网 HTTP 80 → Nginx → 宿主机 `127.0.0.1:8001` → 容器内 `8000` → Gunicorn / Flask → 宿主机 MariaDB。

| 组件 | 地址或名称 | 用途 |
| --- | --- | --- |
| Nginx | 宿主机 80 | 正式 HTTP 入口，反向代理至 8001 |
| 正式容器 | `sre-app-dev` | 运行容器化应用 |
| 容器端口映射 | `127.0.0.1:8001:8000` | 宿主机 8001 映射至容器 8000 |
| 原 systemd 应用 | 宿主机 `127.0.0.1:8000` | 保留的备用应用，最后一次验证时可用 |
| MariaDB | 宿主机网桥地址 `172.17.0.1` | 为应用提供数据存储 |
| 临时验证入口 | 宿主机 `127.0.0.1:8002` | 首次 GHCR 部署前使用，验证容器已清理 |

宿主机 8000 与容器内部 8000 属于不同网络环境。容器内 `127.0.0.1` 指向容器自身，不能用它访问宿主机 MariaDB。

原应用与容器应用共享 `sre_db.server_info` 表，业务代码和进程独立，但不是数据库隔离的两套环境。切换镜像不会自动回退数据库数据；本文的回退演练未涉及数据库迁移。

## 3. 配置文件与运行约束

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | 基于 Python 3.11 slim 安装依赖、复制 `app/`，以普通用户运行单 worker Gunicorn |
| `.dockerignore` | 排除 Git 历史、虚拟环境、环境变量文件及无关资料 |
| `.github/workflows/ci.yml` | 定义构建、冒烟测试和 GHCR 发布流程 |
| `compose.yaml` | 仓库中的可参数化部署模板 |
| `.gitattributes` | 使用 `*.sh text eol=lf` 固定 Shell 脚本换行符 |
| `scripts/prepare-deploy.sh` | 准备镜像并保存部署记录 |
| `scripts/apply-deploy.sh` | 执行部署、检查结果，失败时尝试回退 |
| `configs/nginx/sre-lab.conf` | Nginx 业务入口配置 |
| `configs/prometheus/prometheus.yml` | 指标采集配置 |
| `configs/alloy/config.alloy` | 日志采集配置 |
| `/etc/sre-container.env` | 服务器私有数据库配置；root 所有，权限 0600，不提交 Git |

服务器部署目录：`/home/sre/sre-lab-build/v2.0`。

### 3.1 容器运行参数

- 容器名：`sre-app-dev`；Compose 服务名：`app`。
- 网络：`network_mode: bridge`。
- 内存限制：256 MiB；CPU 配额：0.5 个 CPU。
- 应用端口仅绑定宿主机 `127.0.0.1:8001`。
- 重启策略：`unless-stopped`。
- 健康检查：容器内请求 `/api/status`，周期 30 秒，超时 5 秒，失败重试 3 次，启动宽限期 15 秒。
- 日志输出至标准输出和标准错误；Docker 使用 `json-file`，配置 `max-size: "10m"`、`max-file: "3"`。
- 服务器已启用 `docker.service` 和 `containerd.service` 开机启动。

`Up` 只表示容器主进程运行；`healthy` 只表示配置的健康检查通过。当前健康检查不访问数据库，不能代替数据库接口验证。

健康检查本身不会自动重启容器。主进程退出后的恢复由重启策略处理；部署时健康检查失败后的回退由部署脚本处理。

### 3.2 数据库权限

容器使用账号 `sre_container@172.17.0.0/255.255.255.0`，仅授予 `sre_db.server_info` 表的 `SELECT`、`INSERT`、`UPDATE`、`DELETE` 权限。

更换 Docker 网络或服务器环境时，需要重新核对数据库地址、网桥网段和账号来源限制。数据库凭据通过 `/etc/sre-container.env` 注入，不打入镜像。

### 3.3 仓库模板与服务器配置

仓库 `compose.yaml` 使用以下形式选择镜像：

```yaml
image: "${APP_IMAGE:-ghcr.io/olivia317/sre-lab@sha256:08b2db2c35d11c7fe89bab777c22b89616b3abbfcdef05aa98d7873237362e16}"
```

传入非空 `APP_IMAGE` 时使用指定镜像；否则使用已验证镜像作为默认值。

服务器保留 `compose.parameterized.yaml` 作为准备模板。执行脚本将选定的具体镜像地址写入正式 `compose.yaml`，避免部署结果依赖 SSH 会话中的临时变量。

修改环境文件后，需要重新创建容器使配置生效，单纯 `restart` 不会重新读取环境文件。

## 4. 版本识别与 CI 发布

### 4.1 提交、镜像与运行容器的区别

| 标识 | 含义 |
| --- | --- |
| Git 提交号 | 整个仓库的一次文件快照，修改文档也会产生新提交 |
| 镜像标签 | 镜像名称中的版本标签；本项目使用 `sha-<完整提交号>` |
| 镜像摘要 | 镜像发布内容的确定标识；正式部署使用 `@sha256:…` |
| 镜像 ID | 本地镜像标识，可通过 Docker inspect 查看 |
| 容器 ID | 某个运行实例的标识；重建容器后通常改变 |

Git 提交号不是镜像摘要。部署文档更新后，仓库可以有新提交，而服务器继续运行之前已验证的镜像。

Dockerfile 仅复制应用目录，并不会将整个仓库都放进镜像。即使业务代码未变，构建时写入的 `revision` 标签改变，也会使镜像身份发生变化；重新构建还可能受到基础镜像变化等因素影响。

### 4.2 当前已部署镜像

- 来源提交：`52f765bf7db4204d162ebf688dc310a4e9f504b5`。
- 镜像标签：`ghcr.io/olivia317/sre-lab:sha-52f765bf7db4204d162ebf688dc310a4e9f504b5`。
- 部署地址：`ghcr.io/olivia317/sre-lab@sha256:08b2db2c35d11c7fe89bab777c22b89616b3abbfcdef05aa98d7873237362e16`。

上述镜像用于首次 GHCR 部署和同镜像配置回退演练。2026-10-14 19:01，通过部署脚本完成跨镜像切换，当前正式应用运行版本为：

- 源码提交：`0f979335f06b8ac98c3bd390563f1c2b89fcba2b`。
- 镜像地址：`ghcr.io/olivia317/sre-lab@sha256:22e54f9bc41ed6deac3f4c23298f2251c768fc3e355b94deee6aa169998ded49`。

仓库 Compose 模板的默认镜像仍为首次部署的 `08b2db2c…` 镜像，与服务器当前运行版本分别记录。提交代码、文档或重新运行 CI，不会自动更换服务器运行版本。

### 4.3 CI 工作流

触发条件：

- 向 `main` 或 `feature/v2.0-docker` 分支 push。
- 面向 `main` 的 PR 创建、更新等配置所覆盖的事件。

执行顺序：取出代码 → 构建镜像 → 启动临时容器 → 等待应用就绪 → 验证接口 → push 事件下登录并发布 GHCR → 输出日志并清理临时容器。

冒烟测试检查：

- `/api/status` 返回 HTTP 200，`status` 为 `running`，且存在 `server` 字段。
- `/metrics` 返回 HTTP 200，且包含 `flask_http_requests_total` 指标样本。

镜像构建时写入 `org.opencontainers.image.source` 和 `org.opencontainers.image.revision` 标签。测试通过后给同一个镜像添加 GHCR 标签并上传，不重新构建发布镜像。

CI 使用 `GITHUB_TOKEN` 发布；PR 只测试，不发布。服务器通过具有 `read:packages` 权限的 PAT classic 拉取私有镜像。凭证不进入 Git。

验证边界：CI 当前不连接真实 MariaDB，不测试完整 CRUD，也不执行服务器部署脚本。其成功不等于正式环境已经更新。

## 5. 部署脚本与操作方法

### 5.1 准备阶段

`prepare-deploy.sh` 接收 GHCR 镜像摘要地址，完成：

1. 检查 root 权限、参数格式和目标 Compose 配置。
2. 检查正式容器正在运行，记录其实际镜像引用和镜像 ID。
3. 拉取目标镜像，记录目标镜像 ID。
4. 在 `/var/lib/sre-lab/releases/` 下创建独立目录，保存配置及版本信息。
5. 写入状态 `prepared`。

准备阶段不会切换正式容器。部署记录中包括：

| 文件 | 用途 |
| --- | --- |
| `compose.before.yaml` | 部署前的正式配置 |
| `compose.target.yaml` | 本次准备使用的参数化模板副本 |
| `previous-image-ref` / `previous-image-id` | 旧镜像引用及 ID |
| `target-image-ref` / `target-image-id` | 目标镜像引用及 ID |
| `status` | 本次操作状态 |

服务器执行示例：

```bash
cd /home/sre/sre-lab-build/v2.0
sudo bash prepare-deploy.sh \
  'ghcr.io/olivia317/sre-lab@sha256:08b2db2c35d11c7fe89bab777c22b89616b3abbfcdef05aa98d7873237362e16'
```

### 5.2 执行阶段

`apply-deploy.sh` 接收本次准备记录目录，完成：

1. 检查目录、状态及 root 权限。
2. 获取文件锁，避免多个执行脚本同时部署。
3. 核对正式配置和实际镜像是否仍与准备记录一致。
4. 将目标镜像摘要写入部署配置，校验后替换正式配置。
5. 执行 `docker compose up --wait`，等待容器健康。
6. 核对运行镜像 ID，检查直连 8001 和 Nginx 入口的数据库接口均返回 HTTP 200。
7. 成功写入 `deployed`；切换阶段失败则保存日志并尝试回退。

执行示例中的目录必须替换为本次准备脚本实际输出的目录；不要复用已经执行完毕的记录。

```bash
sudo bash apply-deploy.sh /var/lib/sre-lab/releases/<本次准备目录>
```

| 状态 | 含义 |
| --- | --- |
| `prepared` | 准备完成，尚未执行部署 |
| `deploying` | 部署已进入配置切换阶段 |
| `deployed` | 部署及检查成功 |
| `rolled-back` | 目标部署失败，回退和检查成功 |
| `rollback-failed` | 自动回退未通过，需要人工介入 |

回退成功时脚本仍返回退出码 1，表示目标部署失败。脚本通过退出处理尝试回退，但不能保证在断电、进程被强制杀死等所有情况下执行恢复。SSH 不稳定时，可通过 systemd 临时服务运行脚本，并使用 journalctl 查看结果。

### 5.3 常用检查

在服务器部署目录执行：

```bash
sudo docker compose config -q
sudo docker compose ps
sudo docker inspect --format \
  'Image={{.Image}} Health={{.State.Health.Status}} Restart={{.HostConfig.RestartPolicy.Name}}' \
  sre-app-dev
curl --fail --max-time 5 -sS -o /dev/null \
  -w 'Business HTTP %{http_code}\n' http://127.0.0.1/api/servers
```

`config -q` 仅校验配置，不打印展开后的数据库凭据。检查命令不会替代实际部署。

## 6. 已完成的验证记录

### 6.1 初始容器化与 Compose 迁移

- 初始镜像使用本地标签 `sre-lab-app:v2.0-dev`。
- 容器状态接口和数据库查询接口返回 HTTP 200。
- 修复 `jsonoify` 拼写后，缺少 `status` 的更新请求返回 HTTP 400。
- 原测试容器停止并改名为 `sre-app-dev-before-compose`，再由 Compose 创建 `sre-app-dev`。
- 迁移后容器数据库接口及原业务接口均返回 HTTP 200。

历史构建命令为 `sudo docker build -t sre-lab-app:v2.0-dev .`。当前正式部署已改用 GHCR 摘要地址，仅重新构建该本地标签不会更新当前正式容器。

### 6.2 日志配置与主进程退出恢复（2026-09-23）

重建容器后通过 inspect 确认 `json-file`、`max-size=10m` 和 `max-file=3` 生效；未通过填满日志验证实际轮转。

向容器 PID 1 的 Gunicorn 主进程发送 SIGTERM，观察结果：

- 容器 ID 不变，`RestartCount` 从 0 增加到 1。
- 09:51:54 UTC 主进程退出，09:51:55 UTC Gunicorn 重新启动。
- 09:52:00 UTC 健康检查接口返回 200。
- 容器恢复 running / healthy，容器数据库接口和原应用接口均返回 HTTP 200。

本次验证主进程退出后的自动恢复，不包含进程卡死、单纯 unhealthy 或服务器重启场景。

### 6.3 容器 CRUD（2026-09-23）

通过 SSH 本地转发，将电脑 18001 转发至服务器 `127.0.0.1:8001`。使用唯一名称创建专用测试记录：

1. POST 返回 201。
2. GET 查询到新增记录及 ID。
3. PUT 将状态从 running 改为 stopped。
4. 再次 GET，确认修改已落库。
5. DELETE 后再次 GET，确认记录已删除。

测试记录已清理。本次验证正常 CRUD 路径，未覆盖全部异常输入和并发场景；独立测试端口不代表数据库隔离。

### 6.4 Nginx 与可观测性迁移（2026-09-23）

**Nginx：** 将业务上游从 8000 改为 8001，`nginx -t` 通过后 reload。本机 Nginx、容器直连与公网入口返回相同容器 hostname；数据库查询和 `/nginx_status` 正常。原应用 8000 数据库接口也返回 HTTP 200。

**Prometheus：** 将 `flask` 任务目标从 `127.0.0.1:8000` 改为 `127.0.0.1:8001`。promtool 校验通过后发送 SIGHUP 热加载，验证 `up{job="flask",instance="127.0.0.1:8001"}=1`。现有 Flask 可用性告警按 job 匹配，无需为端口变化修改表达式；Grafana 面板是否引用旧 instance 仍待核对。

**Alloy / Loki：** 增加 Docker 发现、筛选和日志采集，仅采集 `sre-app-dev`，复用 `loki.write.local`。日志标签为 `host="sre-lab"`、`service="sre-app"`、`log_type="docker"`、`container="sre-app-dev"`。

将 alloy 用户加入 docker 组并重启服务；该权限变更不包含在 config.alloy 中。docker 组具有高权限，不是只读日志权限。保留原 systemd 应用的 journal 采集。

经 Nginx 请求 `/api/status?probe=alloy-docker-check` 后，在 Loki 查到对应容器日志，确认采集链路贯通。

### 6.5 首次 GHCR 镜像正式部署（2026-10-14）

使用第 4.2 节记录的镜像，执行：

1. 拉取镜像，通过 revision 标签核对来源提交。
2. 在本地 8002 启动临时容器，注入现有数据库配置。
3. 验证状态接口和数据库查询均返回 HTTP 200。
4. 备份正式 Compose，将镜像改为 GHCR 摘要地址。
5. 重建正式容器并等待健康检查通过。
6. 验证 Nginx 返回的 hostname 与新容器一致，数据库接口返回 200。
7. 验证 Prometheus Flask target 为 up=1。
8. 经 Nginx 发出 `probe=ghcr-deploy-20261014` 请求，在 Loki 查到对应日志。
9. 清理临时验证容器，保留旧镜像并提交配置和文档。

本次为手动部署，数据库验证仅执行读取；没有重新执行完整 CRUD 测试。

### 6.6 部署脚本成功路径（2026-10-14）

准备记录：`/var/lib/sre-lab/releases/20261014-145058-RQ9f7g`。

目标镜像与当前镜像相同。准备脚本成功保存记录；执行脚本完成检查，状态为 `deployed`。正式容器没有重建，健康检查和两个数据库查询接口均通过。

该测试验证同镜像执行的成功路径，不代表已验证不同镜像之间的切换。

### 6.7 健康检查失败后的自动回退（2026-10-14）

使用同一个镜像，仅将本次记录目录中 `compose.target.yaml` 的健康检查改为 `import sys; sys.exit(1)`。通过 systemd 临时服务执行 apply-deploy.sh，原始配置保留在 `compose.before.yaml`。

| 北京时间 | 事件 |
| --- | --- |
| 18:31:46 | 开始执行部署，重建容器 |
| 18:33:04 | 目标容器被判定为 unhealthy |
| 18:33:05 | 脚本开始自动回退 |
| 18:33:15 | 恢复正常配置，容器健康，数据库接口验证通过 |

验收结果：

- 状态为 `rolled-back`。
- 正式镜像仍为第 4.2 节的镜像，容器 healthy。
- Nginx 数据库接口返回 HTTP 200。
- 正式 Compose 与 `compose.before.yaml` 比对一致，cmp 退出码为 0。
- 脚本退出码为 1，systemd 标记任务 failed；含义是目标部署失败，而非回退失败。

演练记录：`/var/lib/sre-lab/releases/20261014-182835-ivVoTd`。

任务名称：`sre-rollback-drill-20261014-183121.service`。

从开始回退到验证完成约 10 秒；未持续测量请求成功率，不能将该时间解释为业务中断时长。

本次证明了健康检查配置失败后的自动配置回退，未验证跨镜像回退、数据库迁移回退或全部故障类型。

### 6.8 不同镜像的脚本部署（2026-10-14）

通过 prepare-deploy.sh 和 apply-deploy.sh，将正式应用从
52f765b 构建的镜像切换至 0f97933 构建的镜像。

- 部署记录：`/var/lib/sre-lab/releases/20261014-185915-HcSR4V`。
- 部署状态：`deployed`。
- 容器重新创建，镜像 Revision 核对正确，健康状态为 healthy。
- 容器直连及 Nginx 数据库接口检查通过。
- Prometheus：`up{job="flask",instance="127.0.0.1:8001"} = 1`。
- Loki：查到包含 `script-deploy-0f97933` 的容器访问日志。

本次验证不同镜像之间的成功切换，未引入业务功能变化。
跨镜像部署失败后的自动回退仍待验证。

## 7. 回退方法与适用范围

三种回退的目标不同，不能混用备份。

### 7.1 恢复某次脚本部署前的配置

适用于脚本部署失败且需要人工介入的情况。先确认后台部署任务已经结束，避免与脚本同时修改配置。选择对应记录目录中的备份，不要直接使用其他演练目录。

```bash
cd /home/sre/sre-lab-build/v2.0
# 替换为本次实际记录目录。
release_dir='/var/lib/sre-lab/releases/<本次准备目录>'
sudo cp -a "$release_dir/compose.before.yaml" compose.yaml
sudo docker compose up -d --no-deps --pull never --wait --wait-timeout 120 app
```

恢复后检查镜像 ID、容器健康、直连与 Nginx 数据库接口，并按需检查指标和日志。旧镜像必须仍在本地。

### 7.2 从首次 GHCR 部署退回本地镜像

历史备份：`/home/sre/sre-lab-build/v2.0/compose.yaml.before-ghcr-20261014-104918`。

该备份引用 `sre-lab-app:v2.0-dev`，对应首次 GHCR 部署前的本地镜像。需要明确退回该版本时才使用，不是当前每次部署的通用恢复点。

```bash
cd /home/sre/sre-lab-build/v2.0
sudo cp -a compose.yaml.before-ghcr-20261014-104918 compose.yaml
sudo docker compose up -d --no-deps --pull never --wait --wait-timeout 120 app
```

该跨镜像恢复路径已准备，尚未实际演练；本次健康检查失败的配置回退不构成对此路径的验证。

### 7.3 将业务入口退回原 systemd 应用

切换前 Nginx 备份：`/etc/nginx/sre-lab.conf.before-container-20260923-190139`。

先验证原应用 `127.0.0.1:8000/api/servers` 正常，再将备份恢复至 `/etc/nginx/conf.d/sre-lab.conf`，执行 `nginx -t`，通过后 reload。业务回到原应用后，还需同步核对 Prometheus 采集目标与日志查询对象。

原 systemd 应用只是备用运行路径，仍与容器共享数据库。

## 8. 运维记录与排障注意事项

- DNF 定时缓存刷新曾占用软件包管理锁；识别任务后停止缓存刷新。历史日志显示过 dnf 相关 OOM，但不能据此断言它就是某次 SSH 断连的原因。
- 服务器已启用 2 GiB `/swapfile-sre`；2026-10-06 写入 fstab，并禁用 dnf-makecache.timer。已验证配置与当时运行状态，未据此宣称完成重启验证。
- Docker Hub 曾连接超时，配置腾讯云内网镜像加速源后成功拉取测试镜像。
- 数据库原账号只允许 localhost，后新增来源受限的容器账号。
- `docker compose up` 默认附着终端；后台运行使用 `up -d`。
- Docker 引擎 active 不代表应用容器已经运行；需要分别检查引擎、容器和业务接口。
- SSH 会话断开不等于服务器重启；可结合 uptime、容器状态和接口响应判断。
- 宿主机显示北京时间（UTC+8），应用日志通常显示 UTC。排查前统一时区。

## 9. 后续工作

1. 验证跨镜像部署失败后的自动回退；不同镜像之间的成功切换已验证。
2. 为部署脚本增加 CI 检查，逐步覆盖参数错误、配置变化、拉取失败、锁冲突和恢复失败等路径。
3. 接入 GitHub Actions 触发服务器部署，明确部署凭证、权限、并发控制和人工恢复方式。
4. 核对 Grafana 面板是否引用旧的 Flask instance。
5. 验证日志实际轮转、数据库备份恢复，并逐步补充异常输入及其他故障场景。
6. 优化工作流触发范围，减少仅修改文档时不必要的镜像构建与发布。

## 10. 面试表述

我将 Flask 应用容器化，使用 Compose 管理资源限制、健康检查、重启策略和日志配置，并将 Nginx、Prometheus 和 Alloy 日志采集迁移到容器应用。

我通过 GitHub Actions 自动构建并执行冒烟测试，测试通过后将同一个镜像发布到 GHCR。服务器按镜像摘要部署，保留来源提交、旧版本和配置记录。

我编写了部署准备与执行脚本，验证了不同镜像之间的成功切换，并通过故意失败的健康检查验证了同镜像下的自动配置回退。部署后核对镜像来源、容器健康状态、数据库接口、Prometheus 指标和 Loki 日志。当前由人工启动服务器部署脚本，尚未接入 GitHub Actions 触发的服务器部署，也未完成跨镜像失败回退演练。
