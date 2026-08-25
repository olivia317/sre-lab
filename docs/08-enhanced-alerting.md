# V1.1 增强告警体系

## 1. 阶段目标

SRE Lab V1.0 已完成 Prometheus、Grafana 和 Alertmanager 的基础告警链路。

V1.1 在此基础上进一步增加：

- 主机资源告警
- 服务存活告警
- 数据库连接率告警
- 告警严重程度分类
- 告警持续时间控制
- 真实邮件通知
- Firing 与 Resolved 通知验证

最终链路：

```text
系统或服务异常
        ↓
Exporter / Application Metrics
        ↓
Prometheus 告警规则
        ↓
Alertmanager
        ↓
QQ SMTP
        ↓
Outlook 收件邮箱
```

---

## 2. 告警规则

V1.1 共配置 8 条告警规则。

### 2.1 主机资源告警

| 告警名称 | 触发条件 | 持续时间 | 级别 |
| --- | --- | --- | --- |
| HighCPUUsage | CPU 使用率 > 80% | 5 分钟 | warning |
| HighMemoryUsage | 内存使用率 > 80% | 5 分钟 | warning |
| HighDiskUsage | 根分区使用率 > 90% | 5 分钟 | critical |

CPU 使用率：

```promql
100 - (
  avg by(instance) (
    rate(node_cpu_seconds_total{mode="idle"}[5m])
  ) * 100
)
```

内存使用率：

```promql
100 * (
  1 - (
    node_memory_MemAvailable_bytes
    /
    node_memory_MemTotal_bytes
  )
)
```

根文件系统使用率：

```promql
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

通过 `for: 5m` 要求资源指标持续异常后再触发告警，避免短暂峰值造成误报。

### 2.2 服务存活告警

| 告警名称 | 检测对象 | 持续时间 | 级别 |
| --- | --- | --- | --- |
| NodeExporterDown | Node Exporter | 1 分钟 | critical |
| NginxDown | Nginx 服务 | 1 分钟 | critical |
| FlaskDown | Flask 应用 | 1 分钟 | critical |
| MariaDBDown | MariaDB 服务 | 1 分钟 | critical |

其中：

```promql
up{job="node_exporter"} == 0
```

检测 Prometheus 是否能够抓取 Node Exporter。

```promql
nginx_up == 0
```

检测 Nginx Exporter 是否能够访问真实 Nginx 服务。

```promql
up{job="flask"} == 0
```

检测 Prometheus 是否能够直接抓取 Flask `/metrics`。

```promql
mysql_up == 0
```

检测 mysqld_exporter 是否能够连接真实 MariaDB 服务。

需要注意：

> Prometheus 的 `up` 表示 Target 是否可以被抓取，不一定等同于 Target 后面的真实服务存活。

### 2.3 数据库连接率告警

告警名称：

```text
MariaDBHighConnectionUsage
```

表达式：

```promql
100 *
mysql_global_status_threads_connected
/
mysql_global_variables_max_connections
> 80
```

计算模型：

```text
数据库连接使用率
= 当前连接数 / 最大连接数 × 100%
```

测试时当前连接使用率约为 1.32%，告警状态为 `inactive`。

---

## 3. 规则验证与部署

新规则先在本地 Git 功能分支编写，再上传到服务器临时目录：

```text
/home/sre/alerts-v1.1.yml
```

使用 `promtool` 验证：

```bash
promtool check rules /home/sre/alerts-v1.1.yml
```

验证结果：

```text
SUCCESS: 8 rules found
```

之后备份原规则并替换正式文件：

```text
/etc/prometheus/rules/alerts.yml
```

完整配置检查：

```bash
promtool check config /etc/prometheus/prometheus.yml
```

通过后重启 Prometheus，并使用 API 确认规则全部加载。

---

## 4. FlaskDown 故障演练

### 4.1 故障注入

停止 Flask 应用：

```bash
sudo systemctl stop sre-app
```

此时 Nginx 访问后端返回：

```text
502 Bad Gateway
```

Prometheus 检测：

```promql
up{job="flask"} == 0
```

告警状态变化：

```text
inactive
→ pending
→ firing
```

Alertmanager 收到：

```text
alertname = FlaskDown
instance = 127.0.0.1:8000
severity = critical
status = active
```

### 4.2 服务恢复

恢复 Flask：

```bash
sudo systemctl start sre-app
```

验证：

```bash
systemctl is-active sre-app
curl -s http://127.0.0.1:8000/api/status
curl -s http://127.0.0.1/api/status
```

最终：

```text
Prometheus state = inactive
active alerts = 0
Alertmanager FlaskDown alerts = 0
```

完成了真实服务故障的触发与恢复闭环。

---

## 5. 邮件通知

V1.1 使用 QQ 邮箱 SMTP 发送告警邮件，由 Outlook 邮箱接收。

SMTP 连接：

```text
smtp.qq.com:587
STARTTLS
```

Alertmanager 通过独立文件读取 SMTP 授权码：

```text
/etc/alertmanager/qq-smtp-auth
```

权限：

```text
-rw------- alertmanager alertmanager
```

公开仓库中只保留配置模板，不保存：

- 真实发件邮箱
- 真实收件邮箱
- QQ SMTP 授权码

### 5.1 Firing 通知

通过 Alertmanager API 注入安全测试告警：

```text
EmailNotificationTest
```

Outlook 成功收到：

```text
[SRE Lab] firing: EmailNotificationTest
```

![Email Alert Firing](../screenshots/04-email-alert-firing.png)

### 5.2 Resolved 通知

将测试告警标记为恢复后：

```text
Active EmailNotificationTest alerts: 0
```

Outlook 成功收到：

```text
[SRE Lab] resolved: EmailNotificationTest
```

![Email Alert Resolved](../screenshots/05-email-alert-resolved.png)

---

## 6. V1.1 告警闭环

```text
异常发生
→ Prometheus 指标异常
→ 告警进入 pending
→ 持续超过 for 时间
→ 告警进入 firing
→ Alertmanager 分组处理
→ QQ SMTP 发送邮件
→ Outlook 收到 Firing
→ 服务恢复
→ Prometheus 告警 inactive
→ Alertmanager 清除告警
→ Outlook 收到 Resolved
```

V1.1 已将基础告警系统扩展为具有资源监控、服务监控、数据库监控和真实通知能力的告警体系。