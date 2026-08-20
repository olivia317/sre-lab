# V0.8 MariaDB 数据库备份与恢复

## 1. 阶段目标

本阶段主要为 `sre-lab` 项目增加数据库可靠性能力。

之前系统已经完成：

- Nginx 反向代理
- Gunicorn + Flask
- systemd 服务管理
- MariaDB 数据持久化
- Flask CRUD 接口

V0.8 的目标是：

1. 完成 MariaDB 手工备份
2. 验证数据库恢复能力
3. 编写自动备份脚本
4. 实现无交互数据库认证
5. 自动记录备份日志
6. 自动清理旧备份
7. 使用 systemd timer 定时执行备份任务

最终实现：

```text
MariaDB
   ↓
mysqldump
   ↓
Shell Backup Script
   ↓
Backup File + Log
   ↓
systemd service
   ↓
systemd timer
````

---

## 2. 手工数据库备份

首先创建数据库备份目录：

```bash
mkdir -p ~/backups/mysql
```

使用 `mysqldump` 对 `sre_db` 数据库进行备份：

```bash
mysqldump -u sre_app -p sre_db > ~/backups/mysql/sre_db_backup.sql
```

输入数据库用户 `sre_app` 的密码后，即可生成 SQL 备份文件。

检查备份文件：

```bash
ls -lh ~/backups/mysql/
```

查看备份文件部分内容：

```bash
head -20 ~/backups/mysql/sre_db_backup.sql
```

数据库备份文件本质上是一组 SQL 语句，其中包括：

* 表结构创建语句
* 数据插入语句
* 数据库相关配置

---

## 3. 数据恢复验证

仅仅生成备份文件并不能证明备份真正可用，因此进行了实际恢复测试。

### 3.1 创建测试数据

进入数据库：

```bash
mysql -u sre_app -p sre_db
```

插入一条用于恢复测试的数据：

```sql
INSERT INTO server_info(hostname, ip, status)
VALUES ('backup-test', '10.2.0.99', 'running');
```

查看数据：

```sql
SELECT * FROM server_info;
```

---

### 3.2 重新生成数据库备份

退出 MariaDB 后重新执行：

```bash
mysqldump -u sre_app -p sre_db > ~/backups/mysql/sre_db_backup.sql
```

此时备份文件中已经包含 `backup-test` 数据。

---

### 3.3 模拟误删除

再次进入数据库：

```bash
mysql -u sre_app -p sre_db
```

删除测试数据：

```sql
DELETE FROM server_info
WHERE hostname='backup-test';
```

确认数据已删除：

```sql
SELECT * FROM server_info;
```

---

### 3.4 从备份中恢复

退出数据库后执行：

```bash
mysql -u sre_app -p sre_db < ~/backups/mysql/sre_db_backup.sql
```

再次查询：

```bash
mysql -u sre_app -p -e "SELECT * FROM sre_db.server_info;"
```

确认 `backup-test` 数据重新出现。

至此完成：

```text
备份
 ↓
模拟数据丢失
 ↓
执行恢复
 ↓
验证数据
```

数据库备份与恢复闭环测试成功。

---

## 4. 配置无交互数据库认证

如果自动备份脚本使用：

```bash
mysqldump -u sre_app -p sre_db
```

每次执行都会要求手动输入密码，无法实现无人值守自动备份。

因此为当前 Linux 用户配置 MariaDB 客户端认证文件。

创建：

```bash
vim ~/.my.cnf
```

配置：

```ini
[client]
user=sre_app
password=DATABASE_PASSWORD
host=localhost
```

> 实际密码不应提交到 GitHub。

修改权限：

```bash
chmod 600 ~/.my.cnf
```

检查：

```bash
ls -l ~/.my.cnf
```

权限应为：

```text
-rw-------
```

测试无交互访问：

```bash
mysql sre_db -e "SELECT * FROM server_info;"
```

如果能够正常查询，则说明认证配置成功。

之后可直接执行：

```bash
mysqldump sre_db
```

而无需再次手动输入密码。

---

## 5. 编写自动备份脚本

创建脚本目录：

```bash
mkdir -p ~/scripts
```

创建：

```bash
vim ~/scripts/mysql_backup.sh
```

脚本内容：

```bash
#!/bin/bash

BACKUP_DIR="/home/sre/backups/mysql"
DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/sre_db_${DATE}.sql"
LOG_FILE="${BACKUP_DIR}/backup.log"

mkdir -p "$BACKUP_DIR"

mysqldump sre_db > "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    echo "[$(date '+%F %T')] Backup success: $BACKUP_FILE" >> "$LOG_FILE"

    find "$BACKUP_DIR" \
        -type f \
        -name "sre_db_*.sql" \
        -mtime +7 \
        -delete
else
    echo "[$(date '+%F %T')] Backup failed" >> "$LOG_FILE"
    rm -f "$BACKUP_FILE"
    exit 1
fi
```

添加执行权限：

```bash
chmod +x ~/scripts/mysql_backup.sh
```

手动运行：

```bash
~/scripts/mysql_backup.sh
```

检查备份文件：

```bash
ls -lh ~/backups/mysql/
```

实际生成文件：

```text
sre_db_20260819_201702.sql
```

查看日志：

```bash
cat ~/backups/mysql/backup.log
```

实际日志：

```text
[2026-08-19 20:17:02] Backup success: /home/sre/backups/mysql/sre_db_20260819_201702.sql
```

说明自动备份脚本运行成功。

---

## 6. 自动清理旧备份

为了避免备份文件长期积累占满磁盘，在脚本中加入：

```bash
find "$BACKUP_DIR" \
    -type f \
    -name "sre_db_*.sql" \
    -mtime +7 \
    -delete
```

该命令只匹配：

```text
sre_db_*.sql
```

并删除超过 7 天的备份。

不会删除：

```text
backup.log
```

或其他不符合规则的文件。

在手工测试 `find` 命令时发现：

```bash
find "$BACKUP_DIR" ...
```

报错：

```text
find: ‘’: No such file or directory
```

原因是 `BACKUP_DIR` 变量只在 `mysql_backup.sh` 脚本执行过程中定义，当前 Shell 中并不存在该变量。

手工测试时需要直接使用完整路径：

```bash
find /home/sre/backups/mysql \
    -type f \
    -name "sre_db_*.sql" \
    -mtime +7 \
    -print
```

先使用 `-print` 检查匹配结果，再决定是否执行删除操作。

---

## 7. 使用 systemd 管理备份任务

为了进一步实现自动化，将备份脚本注册为 systemd oneshot 服务。

创建：

```bash
sudo vim /etc/systemd/system/mysql-backup.service
```

配置：

```ini
[Unit]
Description=Backup SRE MariaDB Database

[Service]
Type=oneshot
User=sre
ExecStart=/home/sre/scripts/mysql_backup.sh
```

这里：

```ini
Type=oneshot
```

表示服务只执行一次任务，执行结束后退出，而不是持续运行。

重新加载 systemd：

```bash
sudo systemctl daemon-reload
```

测试：

```bash
sudo systemctl start mysql-backup.service
```

查看：

```bash
systemctl status mysql-backup.service
```

实际结果：

```text
Active: inactive (dead)
Process: ... ExecStart=/home/sre/scripts/mysql_backup.sh
code=exited, status=0/SUCCESS
```

日志：

```text
Starting Backup SRE MariaDB Database...
mysql-backup.service: Deactivated successfully.
Finished Backup SRE MariaDB Database.
```

虽然状态显示：

```text
inactive (dead)
```

但：

```text
status=0/SUCCESS
```

表示任务已经成功执行并正常退出。

这是 `Type=oneshot` 服务的正常状态。

---

## 8. 使用 systemd timer 定时备份

创建定时器：

```bash
sudo vim /etc/systemd/system/mysql-backup.timer
```

配置：

```ini
[Unit]
Description=Daily MariaDB Backup Timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

其中：

```ini
OnCalendar=*-*-* 02:00:00
```

表示每天凌晨 2 点执行。

```ini
Persistent=true
```

表示如果服务器在计划执行时间处于关机状态，那么服务器之后重新启动时，可以补执行未完成的任务。

启用 timer：

```bash
sudo systemctl daemon-reload

sudo systemctl enable --now mysql-backup.timer
```

查看状态：

```bash
systemctl status mysql-backup.timer
```

实际结果：

```text
Active: active (waiting)
Trigger: Thu 2026-08-20 02:00:00 CST
Triggers: mysql-backup.service
```

查看全部 timer：

```bash
systemctl list-timers --all | grep mysql-backup
```

实际结果：

```text
Thu 2026-08-20 02:00:00 CST ... mysql-backup.timer mysql-backup.service
```

说明 timer 已经正常运行，并等待下一次定时任务。

---

## 9. 最终验证

手动通过 systemd 执行备份：

```bash
sudo systemctl start mysql-backup.service
```

再次查看目录：

```bash
ls -lh ~/backups/mysql/
```

实际结果：

```text
backup.log
sre_db_20260819_201702.sql
sre_db_20260819_203233.sql
sre_db_backup.sql
```

查看日志：

```bash
tail -5 ~/backups/mysql/backup.log
```

实际结果：

```text
[2026-08-19 20:17:02] Backup success: /home/sre/backups/mysql/sre_db_20260819_201702.sql
[2026-08-19 20:32:33] Backup success: /home/sre/backups/mysql/sre_db_20260819_203233.sql
```

说明：

```text
systemd timer
      ↓
mysql-backup.service
      ↓
mysql_backup.sh
      ↓
mysqldump
      ↓
timestamp backup file
      ↓
backup.log
```

整个自动备份链路已经正常工作。

---

## 10. 本阶段问题记录

### 问题 1：mysqldump Access denied

执行：

```bash
mysqldump -u sre_app -p sre_db
```

出现：

```text
Access denied for user 'sre_app'@'localhost'
```

最终确认原因为数据库密码输入错误。

重新输入正确密码后备份成功。

### 问题 2：systemd service 显示 inactive

执行：

```bash
systemctl status mysql-backup.service
```

看到：

```text
Active: inactive (dead)
```

开始容易误以为服务启动失败。

但进一步查看：

```text
status=0/SUCCESS
```

并且存在：

```text
Finished Backup SRE MariaDB Database.
```

确认这是 `Type=oneshot` 服务执行完成后的正常状态。

### 问题 3：BACKUP_DIR 变量不存在

在当前终端直接执行：

```bash
find "$BACKUP_DIR" ...
```

出现：

```text
No such file or directory
```

原因：

`BACKUP_DIR` 是脚本中的局部 Shell 变量，并没有在当前 Shell 环境中定义。

手工执行时改为完整目录：

```bash
find /home/sre/backups/mysql ...
```

即可。

---

## 11. V0.8 完成情况

当前已经完成：

* [x] MariaDB 手工备份
* [x] 数据恢复测试
* [x] 模拟误删除
* [x] 恢复结果验证
* [x] `.my.cnf` 无交互认证
* [x] Shell 自动备份脚本
* [x] 时间戳备份文件
* [x] 备份日志
* [x] 旧备份自动清理
* [x] systemd oneshot service
* [x] systemd timer
* [x] 每天凌晨 02:00 自动备份

---

## 12. 阶段总结

V0.8 将项目从：

```text
数据库可以正常使用
```

提升到了：

```text
数据库发生数据丢失后可以恢复
```

同时进一步实现：

```text
人工备份
    ↓
自动备份
    ↓
定时备份
    ↓
备份日志
    ↓
备份清理
    ↓
恢复验证
```

这一阶段开始体现 SRE 中比较核心的可靠性思想：

> 备份本身并不是目标，能够在故障发生后真正恢复数据才是目标。

下一阶段：

```text
V0.9 Prometheus + Node Exporter + Grafana
```

开始建设服务器监控与可观测性能力。

