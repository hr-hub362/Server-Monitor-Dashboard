# Server Monitor 使用说明

## 文件说明

- `server_monitor.sh`：Linux 服务器监控脚本
- `monitor_report.html`：本地查询页面模板

## 监控内容

- CPU 使用率
- 内存使用率与已用/总量
- 本地磁盘汇总使用率与已用/总量
- 匹配 `ww/datasource` 的进程是否停止、启动或重启

## 数据保留

- 每 `60` 秒采集一轮
- 仅保留最近 `48` 小时数据
- 页面支持按时间范围、进程事件、CPU 阈值、内存阈值查询

## 服务器启动方式

```bash
chmod +x server_monitor.sh
./server_monitor.sh start
```

## 常用命令

```bash
./server_monitor.sh start
./server_monitor.sh stop
./server_monitor.sh status
./server_monitor.sh run-once
./server_monitor.sh render
```

## 默认输出目录

- 优先输出到脚本相对路径 `../../outputs/server_monitor`
- 如果该目录不存在，则退回到脚本目录下的 `data`

输出目录中会生成：

- `monitor_report.html`
- `monitor_data.js`
- `records.tsv`
- `events.tsv`
- `monitor.state`
- `monitor.log`

## 查询方式

直接用浏览器打开输出目录里的 `monitor_report.html` 即可。

## 进程重启判定

- 上一轮有匹配进程，这一轮签名变化，记为 `restarted`
- 上一轮没有，这一轮重新出现，且历史上出现过，记为 `restarted`
- 上一轮有，这一轮没有，记为 `stopped`
- 第一次观测到进程出现，记为 `started`
