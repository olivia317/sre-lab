# Tencent Cloud Server Initialization



## Environment

- Cloud Provider: Tencent Cloud Lighthouse
- OS: Rocky Linux 9.4
- CPU: 2 Core
- Memory: 2GB
- Disk: 50GB


## User Management
Created normal user:
```bash
useradd sre
```

Added sudo permission:

```bash
usermod -aG wheel sre
```

Verified:
```bash
sudo whoami
```
Output:
```bash
root
```


### Firewall

Enabled firewalld:
```bash
systemctl enable --now firewalld
```

Allowed:
```bash
ssh
http
```
### Nginx
Installed:

```bash
dnf install nginx -y
```

Started:

```bash
systemctl enable --now nginx
```


### Result
Nginx successfully deployed.

Public IP access test passed.

