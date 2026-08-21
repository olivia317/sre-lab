# V1.0 Alertmanager 告警与故障演练

## 1. 阶段目标

在 Prometheus + Grafana 监控体系基础上增加主动告警能力。

目标：

```text
异常发生
   |
Prometheus 检测
   |
告警规则触发
   |
Alertmanager
   |
后续通知渠道
```

本阶段首先完成：

- Alertmanager 安装
- Prometheus 接入 Alertmanager
- InstanceDown 告警规则
- 故障注入
- 告警触发验证
- 服务恢复验证

------

# 2. Alertmanager 部署

Alertmanager 使用独立系统用户运行。

监听：

```
127.0.0.1:9093
```

避免直接暴露公网。

systemd：

```
alertmanager.service
```

检查：

```
systemctl status alertmanager
```

Ready 检查：

```
curl -s http://127.0.0.1:9093/-/ready
```

返回：

```
OK
```

说明 Alertmanager 正常运行。

------

# 3. Prometheus 接入 Alertmanager

编辑：

```
/etc/prometheus/prometheus.yml
```

加入：

```
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "127.0.0.1:9093"
```

整体关系：

```
Prometheus
     |
     v
Alertmanager :9093
```

------

# 4. 告警规则目录

创建：

```
/etc/prometheus/rules/
```

规则文件：

```
/etc/prometheus/rules/alerts.yml
```

Prometheus 配置加载：

```
rule_files:
  - "/etc/prometheus/rules/*.yml"
```

检查：

```
promtool check config /etc/prometheus/prometheus.yml
```

规则检查：

```
promtool check rules /etc/prometheus/rules/alerts.yml
```

------

# 5. InstanceDown 告警

第一条告警规则：

```
groups:
  - name: sre-lab-alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} is down"
          description: "{{ $labels.job }} target {{ $labels.instance }} has been down for more than 1 minute."
```

规则含义：

```
up == 0
   |
持续 1 分钟
   |
severity=critical
   |
InstanceDown
```

------

# 6. 告警状态

Prometheus 告警通常经历：

```
inactive
   |
   v
pending
   |
   v
firing
```

含义：

```
inactive
→ 当前不满足告警条件


pending
→ 已满足条件，但还没有达到 for 指定时间


firing
→ 条件持续达到指定时间，正式触发告警
```

------

# 7. 规则加载验证

查询：

```
curl -s http://127.0.0.1:9090/api/v1/rules
```

成功看到：

```
name: InstanceDown
state: inactive
health: ok
```

说明：

```
规则已加载
规则计算正常
当前没有故障
```

------

# 8. 故障注入

为了验证告警链路，故意停止：

```
sudo systemctl stop nginx-exporter
```

选择停止 exporter 而不是直接停止 Nginx。

原因：

```
Nginx Web 服务仍然正常
```

但：

```
Prometheus 无法继续抓取 Nginx Exporter
```

因此可以安全模拟监控 target Down。

------

# 9. Prometheus 检测故障

停止 nginx-exporter 后：

```
up{job="nginx"}
```

变为：

```
0
```

满足：

```
up == 0
```

告警状态经过：

```
pending
```

持续 1 分钟后进入：

```
firing
```

实际返回：

```
alertname="InstanceDown"
instance="127.0.0.1:9113"
job="nginx"
severity="critical"
```

说明 Prometheus 已成功识别故障 target。

------

# 10. Alertmanager 接收告警

查询：

```
curl -s http://127.0.0.1:9093/api/v2/alerts
```

成功看到：

```
InstanceDown
job="nginx"
instance="127.0.0.1:9113"
severity="critical"
state="active"
```

说明链路：

```
nginx-exporter Down
        |
        v
Prometheus
        |
InstanceDown
        |
        v
Alertmanager
```

已经打通。

------

# 11. 服务恢复

重新启动：

```
sudo systemctl start nginx-exporter
```

Prometheus 恢复：

```
up{job="nginx"}
```

返回：

```
1
```

规则状态：

```
inactive
```

Alertmanager 查询：

```
curl -s http://127.0.0.1:9093/api/v2/alerts
```

返回：

```
[]
```

表示活动告警已经清除。

------

# 12. 完整故障演练流程

```
正常状态
   |
   v
Stop nginx-exporter
   |
   v
Prometheus scrape failed
   |
   v
up = 0
   |
   v
InstanceDown pending
   |
持续 1 分钟
   |
   v
InstanceDown firing
   |
   v
Alertmanager active alert
   |
   v
Start nginx-exporter
   |
   v
up = 1
   |
   v
Alert inactive
   |
   v
Alertmanager cleared
```

------

# 13. 本阶段关键理解

## Prometheus 和 Alertmanager 的职责不同

Prometheus：

```
发现异常
判断规则
生成告警
```

Alertmanager：

```
接收告警
分组
去重
抑制
路由
发送通知
```

所以：

```
Prometheus
≠
Alertmanager
```

两者角色不同。

------

## `up` 指标的重要性

Prometheus 自动生成：

```
up
```

其中：

```
1 = scrape success
0 = scrape failed
```

因此：

```
up == 0
```

是最基础、最通用的 target Down 检测方式之一。

------

## `for` 的作用

规则：

```
for: 1m
```

表示异常必须持续 1 分钟才真正 firing。

作用：

```
避免瞬时网络抖动
避免短暂重启
减少无意义告警
```

------

# 14. 当前阶段成果

-  Alertmanager 安装
-  systemd 管理
-  127.0.0.1:9093
-  Prometheus 接入 Alertmanager
-  rule_files
-  InstanceDown Rule
-  promtool 配置检查
-  告警加载验证
-  nginx-exporter 故障注入
-  pending → firing
-  Alertmanager 接收告警
-  exporter 服务恢复
-  Alert 自动清除

------

# 15. 后续计划

下一步增加更有实际意义的资源告警：

```
HighCPUUsage
HighMemoryUsage
HighDiskUsage
```

以及服务类告警：

```
NginxDown
FlaskDown
MySQLDown
```

后续再接入：

```
Email
Webhook
企业微信 / 飞书 / Telegram 等通知渠道
```

具体通知方式根据实际环境选择。

------

# 16. 阶段总结

本阶段将项目从：

```
可以看到问题
```

升级为：

```
可以自动发现问题
```

整个可靠性链路变成：

```
Metrics
   |
Prometheus
   |
Alert Rule
   |
Alertmanager
   |
Fault Detection
   |
Recovery Verification
```

这是项目从“监控系统”向“告警与故障响应系统”迈出的关键一步。

