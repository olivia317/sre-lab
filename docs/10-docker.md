# V2.0 第一阶段：Flask 容器化与 Compose 管理

## 目标与当前范围

将 Flask + Gunicorn 应用构建为 Docker 镜像，使用 Compose 管理运行配置，
并验证容器能够访问宿主机 MariaDB。

本阶段保留原 systemd 应用，使用独立端口并行验证。
已经切换 Nginx，尚未实现 CI/CD。

## 当前部署关系

- 正式入口：公网 80 → Nginx → 宿主机 127.0.0.1:8001
  → 容器内 8000 → Gunicorn/Flask → 宿主机 MariaDB。
- 原 systemd 应用继续监听宿主机 8000，保留用于回退。
- 两套应用共享数据库，并非数据隔离的两套环境。

## 配置文件

- `Dockerfile`：使用 Python 3.11 slim 基础镜像，安装依赖、复制应用，
  以普通用户运行单 worker Gunicorn，日志输出到标准输出与标准错误。
- `.dockerignore`：排除 Git 历史、虚拟环境、环境变量文件和无关资料。
- `compose.yaml`：记录镜像、端口、网络、环境文件路径和资源限制。
- `/etc/sre-container.env`：服务器私有配置，root 所有、权限 0600，
  保存数据库地址和凭据，不提交 Git。

镜像标签为 `sre-lab-app:v2.0-dev`。
容器内存限制为 256MiB，CPU 配额为 0.5 个 CPU。
宿主机端口仅绑定 `127.0.0.1:8001`。

## 数据库连接

容器内的 127.0.0.1 指向容器自身，因此通过宿主机网桥地址
172.17.0.1 访问 MariaDB。

新增账号 `sre_container@172.17.0.0/255.255.255.0`，
仅授予 `sre_db.server_info` 表的 SELECT、INSERT、UPDATE、DELETE 权限。

Compose 显式使用 `network_mode: bridge`，沿用本次验证的网络。
更换网络或部署环境时，需要重新核对数据库地址与账号来源限制。

## 构建与启动

在服务器项目目录执行：

    sudo docker build -t sre-lab-app:v2.0-dev .
    sudo docker compose config -q
    sudo docker compose up -d --pull never

启动前需要准备私有环境文件，并确保 8001 端口和容器名没有冲突。
`config -q` 只校验配置，不打印展开后的数据库凭据。

修改代码后需要重新构建镜像并更新容器。
修改环境文件后需要重新创建容器，单纯 restart 不会重新读取该文件。

## 验证结果

- 容器 `/api/status` 返回 HTTP 200。
- 容器 `/api/servers` 返回真实数据库记录和 HTTP 200。
- 修复 `jsonoify` 拼写后，缺少 status 的更新请求返回 HTTP 400。
- Compose 迁移后，容器数据库接口和原业务均返回 HTTP 200。
- 本阶段只验证数据库读取，已完成容器 CRUD 全流程验证。

容器 Up 仅表示主进程运行，不能替代业务接口验证。

## 遇到的问题

- DNF 定时缓存刷新占用软件包管理锁：识别任务后正常停止缓存刷新。
- Docker Hub 连接超时：配置腾讯云内网镜像加速源后成功拉取测试镜像。
- 数据库原账号仅允许 localhost：为容器新增来源受限的独立账号。
- `docker compose up` 附着终端：使用 `up -d` 后台运行。

## Compose 迁移与回退

迁移前，停止原测试容器并改名为 `sre-app-dev-before-compose`，
再由 Compose 创建新的 `sre-app-dev`。

需要回退时，先停止 Compose 应用，移开新容器名称，
再把保留的旧容器恢复原名并启动。两个容器不能同时占用宿主机 8001。

原 systemd 应用与 Nginx 配置保持原状，继续承载原业务。

## 后续工作

- 完善容器日志管理，并进行自动重启故障演练。
- 验证容器业务写入与恢复流程。
- 验证后再切换 Nginx，并检查监控和日志采集链路。
- 接入 CI/CD，完成自动构建、发布和回退。

## 运行管理增强

- Compose 增加 restart: unless-stopped 重启策略。
- 增加容器内 /api/status HTTP 健康检查，当前状态为 healthy。
- 健康检查不验证数据库，unhealthy 本身不会触发自动重启。
- 服务器已启用 docker.service 和 containerd.service 开机启动。
- 更新后，容器数据库接口与原业务数据库接口均返回 HTTP 200。
- 自动重启策略已配置，实际故障演练已完成。

## 日志管理与自动重启演练（2026-09-23）

### 日志轮转配置

Compose 使用 json-file 日志驱动，配置 max-size: "10m"、
max-file: "3"。重建容器后，通过 docker inspect 确认参数生效。

本次仅验证配置生效，未通过写满日志验证实际轮转。

### 主进程退出恢复演练

在容器内部向 PID 1 的 Gunicorn 主进程发送 SIGTERM，
随后观察 unless-stopped 策略是否自动恢复容器。

验证结果：
- 容器 ID 不变，RestartCount 从 0 增加到 1。
- 09:51:54 UTC 主进程退出，09:51:55 UTC Gunicorn 重新启动。
- 09:52:00 UTC 健康检查接口返回 200。
- 容器恢复 running / healthy。
- 容器数据库接口和原业务数据库接口均返回 HTTP 200。

本次验证主进程退出后的自动恢复，不包含进程卡死、
健康检查失败或服务器重启场景。

### 时间说明

宿主机显示 +0800，容器日志显示 UTC（+0000）。
排查时需统一时区；北京时间为 UTC 加 8 小时。


## 容器 CRUD 验证（2026-09-23）

通过 SSH 本地端口转发，将电脑的 18001 转发至服务器
127.0.0.1:8001，访问容器应用接口。

使用唯一名称创建专用测试记录，验证结果：
- POST 返回 201。
- GET 查询到新增记录及其 ID。
- PUT 将 status 从 running 修改为 stopped。
- 再次 GET 确认修改生效。
- DELETE 删除该记录，再次 GET 确认记录不存在。

测试记录已清理。两套应用共享宿主机 MariaDB 的
sre_db.server_info 表，8001 测试入口不代表数据库隔离。

本次完成正常路径验证，尚未覆盖全部异常输入和并发场景。


## 业务入口与可观测性迁移（2026-09-23）

### Nginx

将 configs/nginx/sre-lab.conf 对应业务上游由 8000 改为 8001，
通过 nginx -t 后 reload。

验证：
- Nginx 本机入口、容器直连和公网入口返回相同容器 hostname。
- 经 Nginx 查询数据库返回 HTTP 200。
- 原应用 8000 数据库接口返回 HTTP 200。
- /nginx_status 正常。

服务器切换前备份：
/etc/nginx/sre-lab.conf.before-container-20260923-190139

回退时恢复该备份至 /etc/nginx/conf.d/sre-lab.conf，
通过 nginx -t 后 reload。若业务回退到原应用，还需同步调整监控目标。

### Prometheus

将 flask 任务目标由 127.0.0.1:8000 改为 127.0.0.1:8001。
promtool 校验通过后，向 Prometheus 主进程发送 SIGHUP 热加载。

验证：
up{job="flask",instance="127.0.0.1:8001"} = 1

Flask 可用性告警按 job="flask" 匹配，无需修改该表达式。
Grafana 面板是否引用旧 instance 尚待核对。

### Alloy 与 Loki

新增 Docker 容器发现、目标筛选和日志采集配置，
仅采集 sre-app-dev，复用现有 loki.write.local。

标签：
- host="sre-lab"
- service="sre-app"
- log_type="docker"
- container="sre-app-dev"

部署时将 alloy 用户加入 docker 组，并重启 Alloy 使权限生效。
此权限变更不包含在 config.alloy 中；docker 组具有高权限，
不是仅能读取日志的权限。

保留原 systemd 应用的 journal 日志采集。

通过 Nginx 请求：
/api/status?probe=alloy-docker-check

在 Loki 中成功查询到对应容器访问日志，确认采集链路打通。