# Server-Monitor-Dashboard
监控 CPU、内存、磁盘汇总占用，并记录匹配 ww/datasource 的进程是否停止、启动或重启。页面仅保留最近 48 小时数据。
Linux 服务器上的监控方案，核心脚本在 scripts/server_monitor/server_monitor.sh，查询页模板在 scripts/server_monitor/monitor_report.html，使用  说明在 scripts/server_monitor/README.md。我也把初始化后
的页面和空数据文件放到了 outputs/server_monitor/monitor_report.html 和 outputs/server_monitor/
  monitor_data.js。

  这个脚本每 60 秒采集一轮 CPU、内存、磁盘汇总占用，并监控命令行包含 ww/datasource 的进程。数据只保留最近 48 小时，采集结果写入 records.tsv / events.tsv，同时生成
  monitor_data.js，浏览器直接打开 monitor_report.html 就能按时间范围、事件类型、CPU 阈值、内存阈值查询记录，还能看趋势图和重启事件。

  在 Linux 服务器上用法就是：

  chmod +x server_monitor.sh
  ./server_monitor.sh start
  ./server_monitor.sh status

  如果你想直接开始部署，建议把 scripts/server_monitor 目录整体拷到服务器上执行。当前这边是 Windows 沙箱环境，Git Bash 本身启动失败，所以我没法在本机真正跑一遍
  Linux 采集流程；脚本逻辑和文件已经写完，但最终请在目标 Linux 服务器上执行一次 ./server_monitor.sh run-once 或 start 做实机验证。
