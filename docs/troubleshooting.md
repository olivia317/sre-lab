# 遇到的 Nginx 配置问题吗？

## Nginx 虚拟主机冲突导致自定义页面未生效

```bash
nginx: [warn] conflicting server name "_" on 0.0.0.0:80, ignored
```
有两个 server 都监听 80 端口，并且都写了 server_name _;，发生冲突，其中一个被忽略。

# 解决方法（推荐）

我们不要删除系统默认文件。

明确指定你的 server 为默认入口。
```bash
server {
    listen 80 default_server;
    server_name _;
```


# server 选择流程
用户访问：
http://公网IP

请求里面：
Host: 公网IP

Nginx：

第一步：

看监听：
listen 80

找到候选：
server A
server B

第二步：

看：
server_name

匹配：
example.com
blog.com

第三步：

如果都不匹配：

使用：
default_server

# 排障流程
```bash
现象：配置改了，但页面没变化
↓
nginx -t：语法没问题
↓
nginx -T：查看最终生效配置
↓
发现 conflicting server name "_"
↓
定位到多个 server 都监听 80
↓
设置 default_server
↓
reload
↓
页面成功切换
```
