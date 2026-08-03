# 🛠️ Nikki 一键安装与维护脚本

本目录提供 Nikki、Mihomo Smart 内核及 GeoX 数据库的一键安装、更新和维护脚本，适用于 OpenWrt、ImmortalWrt 等兼容固件。

脚本兼容 BusyBox `ash`，支持 GitHub 直连、低速自动切换及多个反向代理备用节点。

> [!IMPORTANT]
> 请使用 `root` 用户通过 SSH 登录路由器后执行脚本。  
> 执行升级前，建议备份 Nikki 配置文件、订阅及自定义规则。

## 📋 脚本列表

| 脚本 | 功能 | 适用场景 |
| --- | --- | --- |
| [`nikki_all_install_update.sh`](./nikki_all_install_update.sh) | Nikki 全方位安装、更新、切换及卸载维护 | 首次安装、版本切换和日常综合维护 |
| [`nikki_geox_install_update.sh`](./nikki_geox_install_update.sh) | 更新 GeoSite、GeoIP、MMDB 和 ASN 数据库 | 只更新 Nikki GeoX 数据 |
| [`nikki_smart_install_update.sh`](./nikki_smart_install_update.sh) | 安装或更新 Smart 内核及 LightGBM 模型 | 只维护 Smart 内核和模型 |

---

# 一、Nikki 全方位安装与维护脚本

## 📖 脚本简介

脚本名称：

```text
nikki_all_install_update.sh
```

这是一个面向 Nikki 的综合安装与维护脚本，支持首次安装、日常更新、内核切换、GeoX 数据库更新、Zashboard 面板维护、自定义 Rule-Set 更新及卸载重置。

### 主要功能

- 检测固件名称、固件版本、LuCI 分支、Linux 内核、CPU 架构、包管理器和防火墙版本
- 识别 OpenWrt、ImmortalWrt 等兼容固件
- 检测 AMD64 v1、v2、v3 指令集等级
- 检查 Nikki 官方安装环境：
  - OpenWrt `>= 24.10`
  - Linux Kernel `>= 5.13`
  - `firewall4`
- 兼容 `APK` 和 `OPKG` 包管理器
- 安装、更新或修复：
  - `nikki`
  - `luci-app-nikki`
  - `luci-i18n-nikki-zh-cn`
- 支持以下 Mihomo 内核：
  - Smart 内核（Alpha with Smart Group）
  - Dev 开发预览版内核（Prerelease-Alpha）
  - 稳定版内核（mihomo-meta）
- 支持 LightGBM 模型：
  - 自动选择
  - 轻量模型
  - 中型模型
  - 大型模型
- 更新 GeoX 数据：
  - GeoSite
  - GeoIP
  - Country MMDB
  - ASN MMDB
- 更新 Zashboard 面板：
  - 完整版
  - 无字体版
  - CDN 字体版
  - FiraSans 字体版
  - MiSans 字体版
  - PingFang 字体版
  - Sarasa 字体版
- 更新 YAML 配置中已存在的远程 `rule-set` 自定义规则集
- 提供自动维护和手动多选维护
- 提供单组件更新及内核快速切换
- 提供 Nikki 一键卸载和残留清理
- 卸载时可选择保留或删除 Nikki 软件源及签名密钥
- 更新前自动备份关键文件，失败时自动回滚
- GitHub 下载默认直连优先，失败或持续低速时自动切换反向代理
- 同一脚本会话内复用软件包索引、Nikki 软件源及 GitHub Release 元数据

## 💻 使用方法

### 推荐方法：下载后执行

```sh
wget -O /tmp/nikki_all_install_update.sh \
  https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/nikki_all_install_update.sh

sh /tmp/nikki_all_install_update.sh
```

下载完成后，根据屏幕菜单选择所需维护项目。

### 一行命令执行

```sh
wget -qO- https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/nikki_all_install_update.sh | sh
```

> [!TIP]
> 交互式菜单建议优先采用“下载后执行”的方式，避免部分终端在管道运行时无法正确读取键盘输入。

## ⚙️ 非交互式使用

### 安装或更新 Nikki，并切换为 Smart 内核

```sh
sh /tmp/nikki_all_install_update.sh \
  --action smart \
  --lgbm auto \
  --yes
```

### 安装或更新 Nikki，并切换为 Dev 开发预览版内核

```sh
sh /tmp/nikki_all_install_update.sh \
  --action alpha \
  --yes
```

### 安装或更新 Nikki，并切换为稳定版内核

```sh
sh /tmp/nikki_all_install_update.sh \
  --action stable \
  --yes
```

### 非交互式卸载 Nikki

```sh
sh /tmp/nikki_all_install_update.sh \
  --action uninstall \
  --yes
```

> [!WARNING]
> 非交互式卸载默认保留 Nikki 官方软件源和签名密钥。  
> 卸载操作会删除 Nikki 配置、运行数据和相关内核，请确认重要文件已经备份。

## 🧠 Smart 内核说明

Smart 内核支持以下策略组：

- `smart`
- `url-test`
- `fallback`
- `select`
- 其他 Mihomo 常规策略组

使用 Smart 内核时，建议搭配包含 `smart` 策略组的 YAML 配置文件。

Dev 开发预览版内核和普通稳定版内核不支持 `smart` 策略组。切换至这些内核后，应同步修改 YAML 配置，否则可能导致配置检查失败或 Nikki 无法启动。

## 🌐 GitHub 下载策略

脚本中的 GitHub Raw、GitHub API 和 GitHub Release 下载均采用以下策略：

1. 优先尝试 GitHub 直连
2. 连接失败或持续低速时切换反向代理
3. 按顺序尝试多个备用反向代理
4. 整轮下载失败后重新从直连开始重试
5. 多轮重试仍失败时跳过当前项目并显示手动更新提示

---

# 二、Nikki GeoX 数据库更新脚本

## 📖 脚本简介

脚本名称：

```text
nikki_geox_install_update.sh
```

该脚本用于单独安装或更新 Nikki 使用的 GeoX 数据库，不修改 Mihomo 内核和 Nikki 插件主体。

### 更新内容

| 数据文件 | 安装位置 | 用途 |
| --- | --- | --- |
| GeoSite | `/etc/nikki/run/GeoSite.dat` | 域名分类数据库 |
| GeoIP | `/etc/nikki/run/GeoIP.dat` | IP 地址分类数据库 |
| Country MMDB | `/etc/nikki/run/Country.mmdb` | 国家或地区 IP 数据库 |
| ASN MMDB | `/etc/nikki/run/ASN.mmdb` | ASN 网络信息数据库 |

默认数据来源：

[MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)

### 主要功能

- 同时更新 GeoSite、GeoIP、Country MMDB 和 ASN MMDB
- 下载到临时目录后进行文件检查
- 检查 DAT 文件大小和 MMDB 文件头
- 安装前自动备份现有数据库
- 更新完成后自动重启 Nikki
- Nikki 重启失败时自动恢复旧数据库
- 使用更新锁，防止多个更新任务同时运行
- GitHub 直连失败或持续低速时自动切换反向代理
- 支持自定义下载地址和安装目录

## 💻 使用方法

### 推荐方法：下载后执行

```sh
wget -O /tmp/nikki_geox_install_update.sh \
  https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/nikki_geox_install_update.sh

sh /tmp/nikki_geox_install_update.sh
```

### 一行命令执行

```sh
wget -qO- https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/nikki_geox_install_update.sh | sh
```

## ⚙️ 常用参数

### 更新后不重启 Nikki

```sh
sh /tmp/nikki_geox_install_update.sh --no-restart
```

稍后可手动重启：

```sh
/etc/init.d/nikki restart
```

### 仅使用 GitHub 直连

```sh
sh /tmp/nikki_geox_install_update.sh --no-proxy
```

### 指定一个反向代理

```sh
sh /tmp/nikki_geox_install_update.sh \
  --proxy https://gh.dpik.top/
```

### 自定义反向代理列表

```sh
sh /tmp/nikki_geox_install_update.sh \
  --proxies "https://gh.dpik.top/ https://ghproxy.net/ https://gh-proxy.com/"
```

### 反向代理优先

```sh
sh /tmp/nikki_geox_install_update.sh --proxy-first
```

### 调整直连低速切换条件

```sh
sh /tmp/nikki_geox_install_update.sh \
  --min-speed 64 \
  --slow-time 20 \
  --direct-timeout 600
```

## 🧩 可用参数

```text
--proxy URL             只使用指定的 GitHub 反向代理
--proxies "URL ..."     自定义反向代理列表
--no-proxy              禁用反向代理
--direct-first          直连优先，默认设置
--proxy-first           反向代理优先
--min-speed KB/s        设置直连最低下载速度
--slow-time 秒          设置持续低速熔断时间
--direct-timeout 秒     设置单次直连最长时间
--no-restart            更新完成后不重启 Nikki
-h, --help              显示帮助
```

## 📝 自定义数据源

可通过环境变量替换默认下载地址：

```sh
GEOSITE_URL="自定义地址" \
GEOIP_URL="自定义地址" \
MMDB_URL="自定义地址" \
ASN_URL="自定义地址" \
sh /tmp/nikki_geox_install_update.sh
```

> [!NOTE]
> 如果 YAML 配置直接使用 `GEOSITE` 或 `GEOIP` 规则，建议安装并定期更新 GeoX 数据。  
> 如果配置完全使用远程 `rule-set` 或 `.mrs` 规则，可根据实际需要选择是否安装。

---

# 三、Nikki Smart 内核更新脚本

## 📖 脚本简介

脚本名称：

```text
nikki_smart_install_update.sh
```

该脚本用于单独安装或更新支持 Smart Group 的 Mihomo Alpha 内核，并可同时安装 LightGBM 模型。

默认内核来源：

[vernesong/mihomo](https://github.com/vernesong/mihomo)

### 主要功能

- 自动检测 CPU 架构
- AMD64 自动检测 v1、v2、v3 指令集等级
- 自动匹配对应架构的 Smart 内核
- 支持 LightGBM 大、中、小模型
- 根据设备性能和剩余存储空间自动选择模型
- 下载后校验 GitHub Release 提供的 SHA-256
- 使用新内核检查当前 Nikki 配置
- 替换前自动备份原内核和模型
- 配置检查或 Nikki 重启失败时自动回滚
- 避免多个内核更新任务同时运行
- GitHub 直连失败或持续低速时自动切换反向代理

### 支持的 LightGBM 模型

| 选项 | 模型文件 | 说明 |
| --- | --- | --- |
| `auto` | 自动选择 | 根据设备性能和剩余空间选择 |
| `small` | `Model.bin` | 轻量模型，适合存储空间较小的设备 |
| `middle` | `Model-middle.bin` | 中型模型，性能和空间占用较均衡 |
| `large` | `Model-large.bin` | 大型模型，适合性能及存储空间充足的设备 |
| `skip` | 不安装 | 只更新 Smart 内核 |

## 💻 使用方法

### 自动选择 LightGBM 模型

```sh
wget -O /tmp/nikki_smart_install_update.sh \
  https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/nikki_smart_install_update.sh

sh /tmp/nikki_smart_install_update.sh --lgbm auto
```

### 一行命令执行

```sh
wget -qO- https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/nikki_smart_install_update.sh | sh -s -- --lgbm auto
```

## ⚙️ LightGBM 模型选择

### 轻量模型

```sh
sh /tmp/nikki_smart_install_update.sh --lgbm small
```

### 中型模型

```sh
sh /tmp/nikki_smart_install_update.sh --lgbm middle
```

### 大型模型

```sh
sh /tmp/nikki_smart_install_update.sh --lgbm large
```

### 跳过模型，只更新内核

```sh
sh /tmp/nikki_smart_install_update.sh --lgbm skip
```

## 🔧 其他常用参数

### 更新后不重启 Nikki

```sh
sh /tmp/nikki_smart_install_update.sh \
  --lgbm auto \
  --no-restart
```

### 跳过当前配置检查

```sh
sh /tmp/nikki_smart_install_update.sh \
  --lgbm auto \
  --no-config-test
```

> [!WARNING]
> 除非明确知道当前配置无法用于测试，否则不建议跳过配置检查。

### 强制重新安装内核

```sh
sh /tmp/nikki_smart_install_update.sh \
  --lgbm auto \
  --force
```

### 指定 GitHub 反向代理

```sh
sh /tmp/nikki_smart_install_update.sh \
  --lgbm auto \
  --proxy https://gh.dpik.top/
```

### 仅使用 GitHub 直连

```sh
sh /tmp/nikki_smart_install_update.sh \
  --lgbm auto \
  --no-proxy
```

## 🧩 可用参数

```text
--lgbm auto|small|middle|large|skip
                         选择 LightGBM 模型
--proxy URL              只使用指定的 GitHub 反向代理
--proxies "URL ..."      自定义反向代理列表
--no-proxy               禁用反向代理
--direct-first           直连优先，默认设置
--proxy-first            反向代理优先
--min-speed KB/s         设置直连最低下载速度
--slow-time 秒           设置持续低速熔断时间
--direct-timeout 秒      设置单次直连最长时间
--no-restart             更新完成后不重启 Nikki
--no-config-test         跳过当前配置检查
--force                  强制重新安装内核和模型
-h, --help               显示帮助
```

---

# 🌐 GitHub 无法直连时

如果连脚本本身都无法从 GitHub 下载，可在 Raw 地址前添加反向代理。

示例：

```sh
wget -O /tmp/nikki_all_install_update.sh \
  "https://gh.dpik.top/https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/nikki_all_install_update.sh"

sh /tmp/nikki_all_install_update.sh
```

脚本启动后，其内部所有 GitHub 下载会继续按照“直连优先、低速切换、反向代理备用”的策略运行。

---

# ⚠️ 注意事项

1. 请使用 `root` 用户执行脚本。
2. 综合维护脚本要求系统满足 Nikki 官方安装条件：
   - OpenWrt `>= 24.10`
   - Linux Kernel `>= 5.13`
   - `firewall4`
3. 单独运行 GeoX 或 Smart 内核脚本前，应先安装 Nikki。
4. 内核、模型或数据库更新期间，请勿断电或强制终止脚本。
5. 更新内核后，应确认 YAML 配置与当前内核功能兼容。
6. Smart 内核支持 `smart` 策略组；Dev 和稳定版内核不支持。
7. GeoX 和 Zashboard 完整版会占用一定闪存空间，请提前确认可用空间。
8. 如果下载失败，脚本会自动尝试备用线路；多轮失败后可稍后重新运行。
9. 脚本会尽量在更新失败时恢复原文件，但重要配置仍建议自行备份。
10. 本项目脚本仅供学习、研究及合法网络环境维护使用。

---

# 🔗 相关项目

- [category-mihomo](https://github.com/FANGSEANG/category-mihomo)
- [OpenWrt Nikki](https://github.com/nikkinikki-org/OpenWrt-nikki)
- [Mihomo](https://github.com/MetaCubeX/mihomo)
- [Mihomo Smart 内核](https://github.com/vernesong/mihomo)
- [Meta Rules Dat](https://github.com/MetaCubeX/meta-rules-dat)
- [Zashboard](https://github.com/Zephyruso/zashboard)
