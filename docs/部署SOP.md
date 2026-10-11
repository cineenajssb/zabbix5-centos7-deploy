# 部署 SOP：Zabbix 5.0 LTS（CentOS 7）

> 本文是完整的可复现部署步骤，实测通过（含重启验证）。
> 标记：✅ 已实测　⚠️ 踩过坑

---

## 0. 选型结论（先看，省半天）

**CentOS 7 上装 Zabbix，包版天花板是 5.0 LTS。**

实测官方 el7 仓库：

| Zabbix 版本 | el7 仓库内容 | 能否装包版 |
|---|---|---|
| 4.0 LTS | server + web + agent 全套 | ✅（已 EOL） |
| **5.0 LTS** | server ✅ agent ✅ **无 web 前端** | ✅（前端取源码） |
| 6.0 LTS | 只有 agent/proxy | ❌ 只能源码编译 |
| 6.4 / 7.0 | 只有 agent | ❌ |

> 官方原文："One of the major changes that were made back in Zabbix 5.2 – we no longer provide packages for RHEL/CentOS 7."

**结论：Zabbix 5.0.47 LTS + MariaDB 10.6.28 + PHP 7.3.33(SCL) + Apache 2.4.6**

---

## 1. 前置条件

- [ ] 虚拟机已开机，VMnet8(NAT) 可访问外网
- [ ] 已配置静态 IP
- [ ] 确认无 IP 冲突

---

## 2. 静态 IP 与主机名

```bash
vi /etc/sysconfig/network-scripts/ifcfg-ens33
```

```ini
BOOTPROTO=none
ONBOOT=yes
IPADDR=192.168.106.10
NETMASK=255.255.255.0
GATEWAY=192.168.106.2
DNS1=114.114.114.114
```

```bash
hostnamectl set-hostname zabbix
echo "192.168.106.10 zabbix" >> /etc/hosts
systemctl restart network && systemctl enable network
```

> ⚠️ 模板机出厂 `BOOTPROTO=dhcp` + `ONBOOT=no` 是没网的根因。

---

## 3. 关防火墙 / SELinux / NetworkManager

```bash
systemctl stop firewalld && systemctl disable firewalld
setenforce 0
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
systemctl stop NetworkManager && systemctl disable NetworkManager
systemctl enable network
```

> SELinux 不关，Apache 读不到 `/usr/share/zabbix`，也连不上 php-fpm socket。

---

## 4. 时间同步

```bash
yum -y install chrony && systemctl enable --now chronyd
chronyc sources -v   # 期望 NTP synchronized: yes
```

> 模板机 `tools.syncTime=FALSE`，时间快 8 小时，Zabbix 出图会全乱。

---

## 5. yum 换源（CentOS 7 已 EOL，必做）

```bash
mkdir -p /root/zabbix-setup/backup
cp -a /etc/yum.repos.d /root/zabbix-setup/backup/yum.repos.d

# MariaDB 10.6
cat > /etc/yum.repos.d/MariaDB.repo <<'EOF'
[mariadb]
name=MariaDB 10.6
baseurl=https://mirrors.aliyun.com/mariadb/yum/10.6/rhel7-amd64/
gpgcheck=0
enabled=1
EOF

# CentOS SCLo（提供 rh-php73）
cat > /etc/yum.repos.d/CentOS-SCLo.repo <<'EOF'
[centos-sclo-rh]
name=CentOS-7 - SCLo rh
baseurl=http://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/rh/
gpgcheck=0
enabled=1
EOF

yum clean all && yum makecache
yum -y update ca-certificates   # ⚠️ 不升会报「证书已过期」
```

---

## 6. 安装数据库 / PHP / Zabbix 组件

```bash
yum -y install MariaDB-server MariaDB-client
yum -y install rh-php73 rh-php73-php-fpm rh-php73-php-cli rh-php73-php-mysqlnd \
  rh-php73-php-gd rh-php73-php-bcmath rh-php73-php-mbstring \
  rh-php73-php-xml rh-php73-php-ldap rh-php73-php-opcache
yum -y install zabbix-server-mysql zabbix-agent zabbix-sql-scripts httpd
```

> 版本卡得很死：MariaDB 10.0~10.6（上限）、PHP ≥7.2。CentOS 7 自带 MariaDB 5.5 / PHP 5.4 都不达标。

---

## 7. 建库导入表结构

```bash
systemctl enable --now mariadb
mysql -uroot <<'EOF'
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '1';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF

zcat /usr/share/doc/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uzabbix -p1 zabbix
```

验收：`mysql -uzabbix -p1 zabbix -e "show tables;" | wc -l` → 期望 **166**

---

## 8. 部署 Web 前端（⚠️ 全场最多坑）

5.0 的 el7 仓库没有 web 前端 RPM，必须从源码取：

```bash
cd /usr/local/src
curl -O https://cdn.zabbix.com/zabbix/sources/oldstable/5.0/zabbix-5.0.47.tar.gz
tar zxf zabbix-5.0.47.tar.gz
mkdir -p /usr/share/zabbix
cp -a zabbix-5.0.47/ui/. /usr/share/zabbix/   # ⚠️ 目录是 ui/，不是 frontends/php
chown -R apache:apache /usr/share/zabbix
```

配置数据库连接（源码版前端读 `<root>/conf/zabbix.conf.php`）：

```bash
mkdir -p /etc/zabbix/web
cp /usr/share/zabbix/conf/zabbix.conf.php.example /etc/zabbix/web/zabbix.conf.php
# 编辑：$DB['TYPE']='MYSQL'; $DB['SERVER']='localhost'; $DB['DATABASE']='zabbix';
#      $DB['USER']='zabbix'; $DB['PASSWORD']='1';

# 软链到前端根目录 conf/
mkdir -p /usr/share/zabbix/conf
ln -sf /etc/zabbix/web/zabbix.conf.php /usr/share/zabbix/conf/zabbix.conf.php
chown -R apache:apache /etc/zabbix/web /usr/share/zabbix/conf
```

> 不建软链 → 页面能打开但一直跳安装向导 setup.php。

---

## 9. 配置 Apache + php-fpm

`/etc/httpd/conf.d/zabbix.conf`：

```apache
Alias /zabbix /usr/share/zabbix

<Directory "/usr/share/zabbix">
    Options FollowSymLinks
    AllowOverride None
    Require all granted
    <FilesMatch \.(php|phar)$>
        SetHandler "proxy:fcgi://127.0.0.1:9000"
    </FilesMatch>
</Directory>

<Directory "/usr/share/zabbix/conf">
    Require all denied
</Directory>
```

php-fpm `www.conf`：`user/group = apache`、`listen = 127.0.0.1:9000`

php.ini：`date.timezone = Asia/Shanghai`、`max_input_vars = 10000`（⚠️ 不设大导入模板会报错）

---

## 10. 配置 Server / Agent

`/etc/zabbix/zabbix_server.conf`：

```ini
DBHost=localhost
DBName=zabbix
DBUser=zabbix
DBPassword=1
```

`/etc/zabbix/zabbix_agentd.conf`：

```ini
Server=192.168.106.10
ServerActive=192.168.106.10
Hostname=zabbix
```

---

## 11. 库内主机名 / 接口对齐（⚠️ 常见坑）

```sql
UPDATE hosts SET host='zabbix' WHERE host='Zabbix server';
UPDATE interface SET ip='192.168.106.10' WHERE ip='127.0.0.1';
```

> 只改 agent 配置不改库 → 日志刷 `host [zabbix] not found`。

---

## 12. 启动并设开机自启

```bash
systemctl enable --now mariadb
systemctl enable --now rh-php73-php-fpm
systemctl enable --now httpd
systemctl enable --now zabbix-server
systemctl enable --now zabbix-agent
```

---

## 验收清单

| # | 命令 / 动作 | 期望结果 |
|---|---|---|
| 1 | `ip -4 addr show ens33` | `inet 192.168.106.10/24` |
| 2 | `hostname` | `zabbix` |
| 3 | 5 个服务 `systemctl is-active` | 全部 active |
| 4 | 端口 80/9000/3306/10050/10051 | 全部监听 |
| 5 | 浏览器 `http://<IP>/zabbix/` | HTTP 200，登录页（非 setup.php） |
| 6 | `/var/log/zabbix/zabbix_server.log` | `host "zabbix": host became available` |
| 7 | 重启后复验 | 服务自动恢复，监控继续采集 |
