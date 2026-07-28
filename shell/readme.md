脚本说明和使用方法：
脚本：update-nikki-geox.sh
Function: CPU Detect Arch: Multi-Arch

相关说明：
- ✅ **更新 GeoSite.dat、GeoIP.dat、Country.mmdb、ASN.mmdb
- ✅ **默认安装到 /etc/nikki/run
- ✅ **下载失败或文件校验失败时不覆盖旧数据库
- ✅ **原子替换并自动重启 Nikki
- ✅ **Nikki 重启失败时自动恢复旧数据库
- ✅ **兼容 OpenWrt BusyBox ash
- ✅ **数据源采用 MetaCubeX/meta-rules-dat，文件名及目录符合 Nikki/Mihomo 的使用方式；Nikki 官方依赖中也包含 curl。Nikki 官方仓库
- ✅ **自动识别并显示：
- **OpenWrt 版本
- **apk 或 opkg
- **x86_64、aarch64、armv7 等架构
- **缺少 curl 时给出对应安装命令

**使用命令：**

```bash
wget -qO- https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/update-nikki-geox.sh | sh
```

若只更新geoX数据、不重启nikki：
```bash
wget -qO- https://raw.githubusercontent.com/FANGSEANG/category-mihomo/refs/heads/main/shell/update-nikki-geox.sh | RESTART_NIKKI=0 sh
```
