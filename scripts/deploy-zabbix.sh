#!/bin/bash
# =============================================================================
# Zabbix 5.0 LTS 部署脚本（CentOS 7）
# 用途：从一台 CentOS 7 机器部署 Zabbix 5.0 LTS（含 MariaDB 10.6 + PHP 7.3）
#
# 免责声明：CentOS 7 已 EOL，本脚本仅供学习参考，勿用于生产环境。
#
# 使用前请按实际情况修改以下变量：
#   ZABBIX_DB_PASSWORD  —— zabbix 库用户密码
#   ZABBIX_SERVER_IP    —— 本机 IP（agent 的 Server/ServerActive）
#
# 执行：bash deploy-zabbix.sh
# =============================================================================

set -e

# ---------- 可配置变量 ----------
ZABBIX_DB_PASSWORD="1"
ZABBIX_SERVER_IP="192.168.106.10"
ZABBIX_VERSION="5.0.47"
# -------------------------------

echo "==> [1/10] 关闭防火墙 / SELinux / NetworkManager"
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true
systemctl enable network 2>/dev/null || true

echo "==> [2/10] 时间同步"
yum -y install chrony >/dev/null
systemctl enable --now chronyd

echo "==> [3/10] 配置 MariaDB 10.6 + SCLo 源"
cat > /etc/yum.repos.d/MariaDB.repo <<EOF
[mariadb]
name=MariaDB 10.6
baseurl=https://mirrors.aliyun.com/mariadb/yum/10.6/rhel7-amd64/
gpgcheck=0
enabled=1
EOF
cat > /etc/yum.repos.d/CentOS-SCLo.repo <<EOF
[centos-sclo-rh]
name=CentOS-7 - SCLo rh
baseurl=http://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/rh/
gpgcheck=0
enabled=1
EOF
yum clean all >/dev/null
yum makecache >/dev/null
yum -y update ca-certificates >/dev/null

echo "==> [4/10] 安装 MariaDB 10.6 + PHP 7.3 + Zabbix 组件"
yum -y install MariaDB-server MariaDB-client >/dev/null
yum -y install rh-php73 rh-php73-php-fpm rh-php73-php-cli rh-php73-php-mysqlnd \
  rh-php73-php-gd rh-php73-php-bcmath rh-php73-php-mbstring \
  rh-php73-php-xml rh-php73-php-ldap rh-php73-php-opcache >/dev/null
yum -y install zabbix-server-mysql zabbix-agent zabbix-sql-scripts httpd >/dev/null

echo "==> [5/10] 初始化数据库"
systemctl enable --now mariadb
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF
zcat /usr/share/doc/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uzabbix -p"${ZABBIX_DB_PASSWORD}" zabbix

echo "==> [6/10] 部署 5.0 源码前端"
cd /usr/local/src
curl -O "https://cdn.zabbix.com/zabbix/sources/oldstable/5.0/zabbix-${ZABBIX_VERSION}.tar.gz"
tar zxf "zabbix-${ZABBIX_VERSION}.tar.gz"
rm -rf /usr/share/zabbix
mkdir -p /usr/share/zabbix
cp -a "zabbix-${ZABBIX_VERSION}/ui/." /usr/share/zabbix/
chown -R apache:apache /usr/share/zabbix

echo "==> [7/10] 配置前端数据库连接"
mkdir -p /etc/zabbix/web
cp /usr/share/zabbix/conf/zabbix.conf.php.example /etc/zabbix/web/zabbix.conf.php
sed -i "s/\$DB\['TYPE'\]\s*=.*/\$DB['TYPE'] = 'MYSQL';/" /etc/zabbix/web/zabbix.conf.php
sed -i "s/\$DB\['SERVER'\]\s*=.*/\$DB['SERVER'] = 'localhost';/" /etc/zabbix/web/zabbix.conf.php
sed -i "s/\$DB\['DATABASE'\]\s*=.*/\$DB['DATABASE'] = 'zabbix';/" /etc/zabbix/web/zabbix.conf.php
sed -i "s/\$DB\['USER'\]\s*=.*/\$DB['USER'] = 'zabbix';/" /etc/zabbix/web/zabbix.conf.php
sed -i "s/\$DB\['PASSWORD'\]\s*=.*/\$DB['PASSWORD'] = '${ZABBIX_DB_PASSWORD}';/" /etc/zabbix/web/zabbix.conf.php
mkdir -p /usr/share/zabbix/conf
ln -sf /etc/zabbix/web/zabbix.conf.php /usr/share/zabbix/conf/zabbix.conf.php
chown -R apache:apache /etc/zabbix/web /usr/share/zabbix/conf

echo "==> [8/10] 配置 Apache + php-fpm"
cat > /etc/httpd/conf.d/zabbix.conf <<'EOF'
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
EOF
phpini=/etc/opt/rh/rh-php73/php.ini
sed -i "s/^;\?date.timezone.*/date.timezone = Asia\/Shanghai/" $phpini
sed -i "s/^;*max_input_vars.*/max_input_vars = 10000/" $phpini
fpm=/etc/opt/rh/rh-php73/php-fpm.d/www.conf
sed -i "s/^user =.*/user = apache/" $fpm
sed -i "s/^group =.*/group = apache/" $fpm
sed -i "s/^listen =.*/listen = 127.0.0.1:9000/" $fpm

echo "==> [9/10] 配置 Server / Agent"
sed -i "s/^#\?\s*DBHost=.*/DBHost=localhost/" /etc/zabbix/zabbix_server.conf
sed -i "s/^#\?\s*DBName=.*/DBName=zabbix/" /etc/zabbix/zabbix_server.conf
sed -i "s/^#\?\s*DBUser=.*/DBUser=zabbix/" /etc/zabbix/zabbix_server.conf
sed -i "s/^#\?\s*DBPassword=.*/DBPassword=${ZABBIX_DB_PASSWORD}/" /etc/zabbix/zabbix_server.conf
sed -i "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" /etc/zabbix/zabbix_agentd.conf
sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}/" /etc/zabbix/zabbix_agentd.conf
sed -i "s/^Hostname=.*/Hostname=zabbix/" /etc/zabbix/zabbix_agentd.conf

mysql -uroot zabbix <<EOF
UPDATE hosts SET host='zabbix' WHERE host='Zabbix server';
UPDATE interface SET ip='${ZABBIX_SERVER_IP}' WHERE ip='127.0.0.1';
EOF

echo "==> [10/10] 启动并设开机自启"
systemctl enable --now mariadb
systemctl enable --now rh-php73-php-fpm
systemctl enable --now httpd
systemctl enable --now zabbix-server
systemctl enable --now zabbix-agent

echo ""
echo "=============================================="
echo "部署完成！访问 http://${ZABBIX_SERVER_IP}/zabbix/"
echo "默认账号 Admin / zabbix"
echo "=============================================="
