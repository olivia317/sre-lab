# V0.9 Prometheus + Grafana 监控体系

## 1. 阶段目标

本阶段为 `sre-lab` 项目增加可观测性能力。

监控对象包括：

- Linux 主机
- Nginx
- Flask / Gunicorn 应用
- MariaDB

整体架构：

```text
Node Exporter -----------+
Nginx Exporter ----------+
Flask /metrics ----------+----> Prometheus ----> Grafana
mysqld_exporter ---------+
```

Prometheus 负责：

- 定时抓取指标
- 保存时间序列数据
- 提供 PromQL 查询

Grafana 负责：

- 查询 Prometheus
- 展示监控 Dashboard

------

## 2. Node Exporter

Node Exporter 用于采集 Linux 主机指标。

监听地址：

```
127.0.0.1:9100
```

主要指标包括：

- CPU
- Memory
- Disk
- Network
- Load Average
- Filesystem

通过 systemd 管理：

```
systemctl status node_exporter
```

验证：

```
curl -s http://127.0.0.1:9100/metrics | head
```

可以看到大量：

```
node_...
```

指标。

------

## 3. Prometheus

Prometheus 监听：

```
127.0.0.1:9090
```

基础配置：

```
global:
  scrape_interval: 15s
```

表示每 15 秒抓取一次指标。

初始配置：

```
scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:9090"]


  - job_name: "node_exporter"
    static_configs:
      - targets: ["127.0.0.1:9100"]
```

配置检查：

```
promtool check config /etc/prometheus/prometheus.yml
```

服务状态：

```
systemctl status prometheus
```

Ready 检查：

```
curl -s http://127.0.0.1:9090/-/ready
```

返回：

```
Prometheus Server is Ready.
```

Target 状态：

```
curl -s http://127.0.0.1:9090/api/v1/targets
```

------

## 4. Grafana

Grafana 安装后由 systemd 管理：

```
systemctl status grafana-server
```

默认监听：

```
:3000
```

本机测试：

```
curl -I http://127.0.0.1:3000/login
```

返回：

```
HTTP/1.1 200 OK
```

------

## 5. Grafana 安全访问

3000 端口没有直接开放公网。

通过 SSH Tunnel 访问：

```
ssh -i "PRIVATE_KEY.pem" \
-L 3000:127.0.0.1:3000 \
sre@SERVER_IP
```

浏览器访问：

```
http://127.0.0.1:3000
```

访问链路：

```
Windows Browser
      |
127.0.0.1:3000
      |
SSH Tunnel
      |
Server Grafana :3000
```

------

## 6. Prometheus 数据源

Grafana 中添加 Prometheus Data Source：

```
http://127.0.0.1:9090
```

通过：

```
up
```

验证 Prometheus target 状态。

正常：

```
1 = UP
0 = DOWN
```

------

# 7. Linux 主机 Dashboard

创建 Dashboard：

```
SRE Lab - Linux Monitoring
```

------

## 7.1 CPU Usage

PromQL：

```
100 - (
  avg by(instance) (
    rate(node_cpu_seconds_total{mode="idle"}[5m])
  ) * 100
)
```

核心逻辑：

```
CPU Usage
=
100% - CPU Idle
```

配置：

```
Visualization: Time series
Unit: Percent (0-100)
Min: 0
Max: 100
```

------

## 7.2 Memory Usage

PromQL：

```
100 * (
  1 - (
    node_memory_MemAvailable_bytes
    /
    node_memory_MemTotal_bytes
  )
)
```

逻辑：

```
Memory Usage
=
1 - Available / Total
```

------

## 7.3 Disk Usage

只监控根分区 `/`：

```
100 * (
  1 -
  (
    node_filesystem_avail_bytes{
      mountpoint="/",
      fstype!~"tmpfs|overlay"
    }
    /
    node_filesystem_size_bytes{
      mountpoint="/",
      fstype!~"tmpfs|overlay"
    }
  )
)
```

逻辑：

```
Disk Usage
=
1 - Available / Total
```

------

## 7.4 Load Average

三条指标：

```
node_load1
node_load5
node_load15
```

Legend：

```
1m
5m
15m
```

Load Average 不等同于 CPU 使用率。

它表示一定时间范围内正在运行或等待资源的任务负载情况。

------

## 7.5 Network Traffic

接收：

```
rate(node_network_receive_bytes_total{device!="lo"}[5m])
```

发送：

```
rate(node_network_transmit_bytes_total{device!="lo"}[5m])
```

Legend：

```
Receive
Transmit
```

Unit：

```
bytes/sec (SI)
```

------

# 8. Nginx 监控

Nginx 开启：

```
location /nginx_status {
    stub_status;
    allow 127.0.0.1;
    deny all;
}
```

验证：

```
curl http://127.0.0.1/nginx_status
```

示例：

```
Active connections: 1
server accepts handled requests
 853 853 1810
Reading: 0 Writing: 1 Waiting: 0
```

------

## 8.1 Nginx Exporter

Nginx Prometheus Exporter 监听：

```
127.0.0.1:9113
```

systemd：

```
nginx-exporter.service
```

验证：

```
curl -s http://127.0.0.1:9113/metrics | grep '^nginx'
```

主要指标：

```
nginx_up
nginx_connections_active
nginx_connections_accepted
nginx_connections_handled
nginx_connections_reading
nginx_connections_writing
nginx_connections_waiting
nginx_http_requests_total
```

------

## 8.2 Prometheus 接入 Nginx

配置：

```
- job_name: "nginx"
  static_configs:
    - targets: ["127.0.0.1:9113"]
```

验证：

```
nginx_up
```

正常：

```
1
```

------

## 8.3 Nginx Dashboard

主要面板：

```
Nginx Status
Nginx Request Rate
Nginx Active Connections
Nginx Connection States
```

Request Rate：

```
rate(nginx_http_requests_total[5m])
```

Active Connections：

```
nginx_connections_active
```

Connection States：

```
nginx_connections_reading
nginx_connections_writing
nginx_connections_waiting
```

------

# 9. Flask 应用监控

Flask 默认不提供 Prometheus Metrics。

因此安装：

```
pip install prometheus_client
```

应用增加：

```
/metrics
```

主要指标：

```
flask_http_requests_total
flask_http_request_duration_seconds
```

其中：

```
*_total
```

表示累计计数。

```
*_duration_seconds
```

表示请求耗时。

```
*_bucket
```

表示 Histogram 不同耗时区间。

------

## 9.1 Prometheus 接入 Flask

配置：

```
- job_name: "flask"
  static_configs:
    - targets: ["127.0.0.1:8000"]
```

验证：

```
up{job="flask"}
```

正常：

```
1
```

------

## 9.2 Flask Dashboard

Flask Status：

```
up{job="flask"}
```

Flask Request Rate：

```
sum(rate(flask_http_requests_total[5m]))
```

Flask Request Latency：

```
sum(rate(flask_http_request_duration_seconds_sum[5m]))
/
sum(rate(flask_http_request_duration_seconds_count[5m]))
```

主要观察：

```
服务是否存活
请求速率
请求延迟
```

------

# 10. MariaDB 监控

创建专用监控数据库用户：

```
mysqld_exporter
```

不使用 root。

监控结构：

```
MariaDB
   |
mysqld_exporter
   |
127.0.0.1:9104
   |
Prometheus
```

------

## 10.1 mysqld_exporter

监听：

```
127.0.0.1:9104
```

验证：

```
curl -s http://127.0.0.1:9104/metrics | grep '^mysql_' | head
```

关键指标：

```
mysql_up
mysql_global_status_threads_connected
mysql_global_status_queries
mysql_global_status_threads_running
```

------

## 10.2 Prometheus 接入 MariaDB

配置：

```
- job_name: "mysql"
  static_configs:
    - targets: ["127.0.0.1:9104"]
```

验证：

```
mysql_up
```

正常：

```
1
```

------

## 10.3 MariaDB Dashboard

主要面板：

```
MySQL Status
MySQL Connections
MySQL Queries/s
MySQL Threads Running
```

查询：

```
mysql_up
mysql_global_status_threads_connected
rate(mysql_global_status_queries[5m])
mysql_global_status_threads_running
```

------

# 11. 当前 Prometheus Targets

当前共 5 个 target：

```
prometheus
node_exporter
nginx
flask
mysql
```

通过：

```
up
```

全部返回：

```
1
```

说明所有监控对象均处于正常状态。

------

# 12. Troubleshooting

## Grafana Repository GPG 错误

现象：

```
repomd.xml GPG signature verification error
```

尝试：

- 重新导入 GPG Key
- 清理 dnf cache
- 单独刷新 repository metadata

仍失败后切换 standalone RPM 安装。

------

## GitHub Release 下载超时

服务器直接访问 GitHub Release 时长时间卡在：

```
0%
```

改为：

```
Windows Download
      |
SFTP / SCP
      |
Server /tmp
```

完成文件传输。

------

## nginx-exporter 启动失败

现象：

```
status=217/USER
```

原因：

systemd 中：

```
User=nginx_exporter
```

但最初创建的是：

```
nginx-exporter
```

用户名不一致。

重新创建：

```
nginx_exporter
```

服务恢复。

------

# 13. 阶段总结

本阶段完成了从：

```
服务可以运行
```

到：

```
服务可以被持续观测
```

的升级。

形成：

```
Host Metrics
Service Metrics
Application Metrics
Database Metrics
       |
       v
Prometheus
       |
       v
Grafana Dashboard
```

为后续告警与故障演练提供了指标基础。