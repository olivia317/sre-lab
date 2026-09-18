# V2.0 第一阶段：Flask 容器化与 Compose 管理

## 目标与当前范围

将 Flask + Gunicorn 应用构建为 Docker 镜像，使用 Compose 管理运行配置，
并验证容器能够访问宿主机 MariaDB。

本阶段保留原 systemd 应用，使用独立端口并行验证。
尚未切换 Nginx，也尚未实现 CI/CD。

## 当前部署关系

| 入口 | 应用 | 数据库 |
| --- | --- | --- |
| Nginx → 127.0.0.1:8000 | 原 systemd Gunicorn/Flask | 宿主机 MariaDB |
| 127.0.0.1:8001 → 容器内 8000 | Compose 管理的 Gunicorn/Flask | 同一宿主机 MariaDB |

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
- 本阶段只验证数据库读取，尚未进行容器 CRUD 全流程验证。

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
- 自动重启策略已配置，实际故障演练尚未执行。