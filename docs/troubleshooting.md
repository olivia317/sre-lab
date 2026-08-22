# Troubleshooting

本文记录 SRE Lab V1.0 建设和收尾过程中遇到的真实问题，以及对应的定位、修复和验证过程。

## 1. Nginx 虚拟主机配置冲突

### 现象

执行配置检查时出现警告：

```text
nginx: [warn] conflicting server name "_" on 0.0.0.0:80, ignored
```

虽然语法检查能够通过，但部分 Server 配置会被 Nginx 忽略。

### 定位

使用以下命令查看 Nginx 最终加载的全部配置：

```bash
sudo nginx -T 2>&1 |
grep -nE '^# configuration file|listen[[:space:]]+80|server_name'
```

发现三个 Server 块同时监听 80 端口，并且都使用了：

```nginx
server_name _;
```

配置分别来自：

```text
/etc/nginx/nginx.conf
/etc/nginx/conf.d/sre-app.conf
/etc/nginx/conf.d/sre-lab.conf
```

### 原因

`default_server` 只能决定未匹配请求的默认入口，不能消除多个相同 `server_name` 之间的冲突。

项目早期配置没有及时清理，导致系统默认站点、旧应用配置和当前正式配置同时生效。

### 修复

保留当前正式配置：

```text
/etc/nginx/conf.d/sre-lab.conf
```

将旧配置改名，使其不再匹配 `*.conf`：

```bash
sudo mv \
/etc/nginx/conf.d/sre-app.conf \
/etc/nginx/conf.d/sre-app.conf.bak
```

将系统默认 Server 的名称改为：

```nginx
server_name localhost;
```

正式站点继续作为默认入口：

```nginx
listen 80 default_server;
server_name _;
```

### 验证

```bash
sudo nginx -t
sudo systemctl reload nginx
curl -s http://127.0.0.1/api/status
curl -s http://127.0.0.1/nginx_status
```

最终 Nginx 配置警告消失，Flask 反向代理和状态页均正常。

---

## 2. Node Exporter systemd 配置错误

### 现象

检查 `node_exporter.service` 时发现：

```ini
User=node_exporter
Grounp=node_exporter
```

同时，Node Exporter 实际监听地址为：

```text
*:9100
```

### 定位

使用 systemd 验证配置：

```bash
sudo systemd-analyze verify \
/etc/systemd/system/node_exporter.service
```

输出：

```text
Unknown key name 'Grounp' in section 'Service', ignoring.
```

检查监听端口：

```bash
sudo ss -lntp | grep ':9100'
```

确认服务监听所有网卡。

### 原因

`Group` 被错误拼写为 `Grounp`，systemd 无法识别该配置项。

同时，Node Exporter 未指定 `--web.listen-address`，因此使用默认监听范围。

### 修复

将服务配置修正为：

```ini
[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
Restart=on-failure
```

重新加载并重启：

```bash
sudo systemctl daemon-reload
sudo systemctl restart node_exporter
```

### 验证

```bash
sudo ss -lntp | grep ':9100'
curl -s http://127.0.0.1:9100/metrics | head
```

通过 Prometheus API 检查 Target：

```bash
curl -s \
'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22node_exporter%22%7D'
```

最终 Node Exporter 仅监听：

```text
127.0.0.1:9100
```

Prometheus 查询结果为 `up = 1`。

---

## 3. Alertmanager 无效 Webhook 重试

### 现象

Alertmanager 日志中持续出现通知重试和发送失败：

```text
Notify attempt failed, will retry later
connect: connection refused
notify retry canceled after 15 attempts
```

### 定位

查询日志：

```bash
sudo journalctl -u alertmanager --since "today" --no-pager |
grep -Ei 'error|fail|refused|notify'
```

发现 Alertmanager 尝试向以下地址发送通知：

```text
127.0.0.1:5001
```

但服务器并未部署对应的 Webhook 接收服务。

### 原因

Alertmanager 使用了示例配置中的 `web.hook` 接收器。告警能够进入 Alertmanager，但通知发送阶段会因为目标不存在而失败。

V1.0 尚未接入邮件、企业微信等真实通知渠道，因此不应该保留无效的 Webhook。

### 修复

将接收器改为空接收器：

```yaml
route:
  group_by:
    - alertname
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 1h
  receiver: 'null'

receivers:
  - name: 'null'
```

验证并重启：

```bash
sudo /usr/local/bin/amtool check-config \
/etc/alertmanager/alertmanager.yml

sudo systemctl restart alertmanager
```

### 验证

```bash
curl -s http://127.0.0.1:9093/api/v2/status
```

API 显示当前接收器为 `null`，重启后的日志不再出现 Webhook 连接失败。

---

## 4. Alertmanager 单机环境开放集群端口

### 现象

检查端口时发现 Alertmanager 的 9094 端口同时监听 TCP 和 UDP：

```text
*:9094
```

### 原因

9094 是 Alertmanager 高可用集群使用的 Gossip 通信端口。

当前项目只有一个 Alertmanager 实例，不需要集群通信，因此无需开放该监听端口。

### 修复

在 `alertmanager.service` 中增加：

```ini
--cluster.listen-address=
```

完整启动参数包含：

```ini
ExecStart=/usr/local/bin/alertmanager \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/var/lib/alertmanager \
    --web.listen-address=127.0.0.1:9093 \
    --cluster.listen-address=
```

重新加载并重启：

```bash
sudo systemctl daemon-reload
sudo systemctl restart alertmanager
```

### 验证

```bash
sudo ss -lntup |
grep -E ':9093|:9094'
```

最终只保留：

```text
127.0.0.1:9093
```

Alertmanager API 返回：

```json
{
  "cluster": {
    "peers": [],
    "status": "disabled"
  }
}
```

至此，单机环境不需要的 9094 集群端口已关闭。