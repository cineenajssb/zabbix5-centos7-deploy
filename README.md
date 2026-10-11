# Zabbix 5.0 LTS 部署与排障（CentOS 7）

> 一个真实的运维排障记录项目：从一台「装到一半、版本错配」的 CentOS 7 虚拟机，修复并部署出可用的 Zabbix 5.0 LTS 监控系统。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Status](https://img.shields.io/badge/Status-部署验证通过-success)
![Zabbix](https://img.shields.io/badge/Zabbix-5.0.47%20LTS-red)
![MariaDB](https://img.shields.io/badge/MariaDB-10.6.28-blue)
![PHP](https://img.shields.io/badge/PHP-7.3.33-purple)

---

## 这是什么？

这不是一份「从零安装 Zabbix」的教程——GitHub 上那种教程已经很多了。

这是一个**真实排障过程的完整复盘**：一台 CentOS 7 虚拟机上，之前有人装 Zabbix 装到一半就停了，留下了「server 是 5.0、web 前端是 6.0、数据库和 PHP 版本都不达标」的混装烂摊子。

我把这台机器**修复**成一个版本统一、能正常出监控图的 Zabbix 5.0 LTS，并记录下每一步的判断和踩过的坑。

### 为什么值得看

- **版本选型结论**：CentOS 7 上装 Zabbix，包版天花板是 5.0 LTS（6.0 官方已不为 CentOS 7 打包）。
- **故障诊断思路**：怎么从 `rpm -qa`、端口监听、服务状态反推出「装到一半」的真相。
- **MariaDB 5.5 → 10.6 原地升级**：不动数据、保留 166 张表。
- **5.0 源码前端部署的隐蔽坑**：前端目录叫 `ui/`（不是 `frontends/php`），配置文件走 `conf/` 软链。
- **可复用的自动化脚本**：通过 VMware Tools 通道（vmrun）在客户机内跑脚本，不必手动敲命令。

---

## 最终架构

| 组件 | 版本 | 说明 |
|---|---|---|
| 操作系统 | CentOS Linux 7.8.2003 | 已 EOL，仅供学习 |
| Zabbix Server | 5.0.47 LTS | server + agent |
| Zabbix 前端 | 5.0（源码 `ui/` 部署） | 走 Apache + php-fpm |
| 数据库 | MariaDB 10.6.28 | 从 5.5 原地升级 |
| PHP | 7.3.33（rh-php73） | SCL 软件集 |
| Web 服务器 | Apache 2.4（httpd） | proxy_fcgi 代理到 php-fpm |

访问地址：`http://<你的IP>/zabbix/`，默认账号 `Admin` / `zabbix`。

---

## 目录结构

```
.
├── README.md              # 本文件
├── docs/
│   ├── 部署SOP.md          # 完整可复现的部署步骤
│   └── 踩坑清单.md          # 现象 → 原因 → 解法（按严重度排序）
└── scripts/
    └── deploy-zabbix.sh    # 一键部署脚本（参考用，含分步注释）
```

---

## 快速开始

> ⚠️ **免责声明**：CentOS 7 已于 2024 年 6 月 EOL，官方 yum 源全部失效。本项目仅供学习排障思路，**不要用于生产环境**。

完整步骤见 [`docs/部署SOP.md`](docs/部署SOP.md)，核心流程：

```bash
# 1. 换源（CentOS 7 已 EOL，官方源全废）
# 2. 关防火墙 / SELinux
# 3. MariaDB 5.5 → 10.6 升级
# 4. 安装 PHP 7.3（SCL）
# 5. 5.0 前端从源码部署
# 6. 启动服务 + 验收
```

---

## 踩坑速览（10 条）

详见 [`docs/踩坑清单.md`](docs/踩坑清单.md)，最关键的 4 个：

1. 🔴 **Zabbix 6.0 在 CentOS 7 没有 server 包** → 只能用 5.0 LTS
2. 🔴 **5.0 官方源也没有 web 前端包** → 前端从源码取
3. 🔴 **5.0 源码前端目录叫 `ui/`**，不是老教程的 `frontends/php`
4. 🔴 **源码版前端读 `<root>/conf/zabbix.conf.php`**，不是 `/etc/zabbix/web/`

---

## License

MIT License — 见 [LICENSE](LICENSE)
