# vps-tcp-tune

给 Linux VPS 提供一个可检查、可回滚的 TCP 发送缓冲区调整工具。它将 `net.ipv4.tcp_wmem` 的第三项提高到 **32 MiB（33554432 字节）**，保留前两项，并保留已经更大的第三项。

这个调整适合排查高延迟 TCP 连接的发送缓冲区限制。实际提速取决于连接是否受这一限制影响；它不保证跑满套餐带宽，也不保证达到 100 MB/s。

## 安装与应用

在目标 VPS 的 **root 终端**执行以下命令，下载固定版本 `v1.0.0` 并应用：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/Yamada-anna1/vps-tcp-tune/v1.0.0/vps-tcp-tune.sh -o /root/vps-tcp-tune.sh && bash /root/vps-tcp-tune.sh apply
```

需要 Linux、Bash 4 或更新版本、`sysctl`、`flock` 及常用系统命令；下载步骤需要 `curl`。脚本不会自动安装依赖。受限容器或不允许修改该 sysctl 的环境可能无法应用。

希望先检查脚本时，可以分开执行：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/Yamada-anna1/vps-tcp-tune/v1.0.0/vps-tcp-tune.sh -o /root/vps-tcp-tune.sh
less /root/vps-tcp-tune.sh
bash /root/vps-tcp-tune.sh apply
```

**已经将最大值设为 32 MiB 或更大的机器，通常无需再次安装。** 本工具首次备份的是安装时的真实状态；如果安装前已经是 32 MiB，回滚也会恢复到该状态，不会猜测历史值为 4 MiB。

## 命令

```bash
bash /root/vps-tcp-tune.sh apply
bash /root/vps-tcp-tune.sh status
bash /root/vps-tcp-tune.sh rollback
bash /root/vps-tcp-tune.sh help
```

| 命令 | 用途 |
| --- | --- |
| `apply` | 检查配置冲突、备份原状态、写入持久化配置并应用当前值 |
| `status` | 查看当前参数及本工具的管理状态，不修改内核参数 |
| `rollback` | 检查后续改动，恢复首次应用前的参数和目标配置文件 |
| `help` | 显示用法 |

## 调整范围

`net.ipv4.tcp_wmem` 包含 `min default max` 三项，单位为字节。本工具根据当前值计算：

```text
新 min     = 当前 min
新 default = 当前 default
新 max     = max(当前 max, 33554432)
```

例如，当前最大值为 4 MiB 时提高到 32 MiB；已经为 64 MiB 时仍保留 64 MiB。最小值和默认值不变。

本工具管理以下位置：

| 路径 | 内容 |
| --- | --- |
| `/etc/sysctl.d/99-vps-tcp-throughput.conf` | 本工具写入的持久化配置 |
| `/var/lib/vps-tcp-tune` | 首次原值、原文件备份及管理状态 |

应用过程仅写入这一个内核参数，并回读确认结果，无需重启。重复运行 `apply` 不会用修改后的状态覆盖首次备份。脚本不调用 `sysctl --system` 来重放所有系统配置。

本工具不修改拥塞控制算法、队列、TCP 接收缓冲区、代理配置、防火墙或用户服务。已有 BBR 等设置保持原样。

## 已有配置与冲突

`99-` 开头的文件名并不意味着一定最后生效。按照 systemd 的规则，同名文件优先选择高优先级目录中的版本，再按文件名字典序处理；同一键可以被后面的文件覆盖。详见 [systemd 的 sysctl.d 文档](https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html)。

为避免静默覆盖已有配置，本工具采用保守检查：

- 按同名文件的目录优先级筛选后，扫描有效的 sysctl 配置文件，并检查 `/etc/sysctl.conf`。
- 除准备备份并接管的目标文件外，发现其他文件对本键声明了不同三元组时，停止应用并报告位置。即使该文件排序较早、理论上能被后续覆盖，也会拒绝，便于先明确配置归属。
- 已有目标文件仅允许包含空行、注释和本键的设置；满足条件时先完整备份，再由本工具接管。若其中还包含其他参数，则停止，避免丢失其他设置。
- 如果目标文件尚不存在，但低优先级目录中已有同名文件，也会停止，避免新增文件遮蔽其他配置。
- 脚本不会自动删除或注释其他文件中的冲突项。

遇到冲突时，先查看脚本指出的文件，确认由哪一处负责这个参数，整理重复声明后再运行 `apply`。不要为通过检查而整份删除系统配置。

当前值回读成功与启动配置已写入，是本工具能够验证的范围。其他配置管理工具或启动任务仍可能再次写入参数；实际重启后的结果应通过 `status` 或下面的命令确认：

```bash
sysctl net.ipv4.tcp_wmem
```

## 回滚

```bash
bash /root/vps-tcp-tune.sh rollback
```

回滚恢复的是**本工具首次应用前**的状态：

- 恢复备份的完整三元组。
- 如果目标配置文件原来存在，恢复原文件；原来不存在，则移除本工具创建的文件。
- 如果当前参数或受管文件出现无法与已记录状态对应的改动，拒绝直接覆盖，并提示检查差异。已经恢复为原状态的部分允许继续完成回滚。
- 成功回滚后，将备份和状态归档到 `/var/lib` 下的相邻目录；具体路径以脚本输出为准。

不要删除状态目录后期待工具自动重建历史值。归档保留的是已结束的一次应用记录；再次安装将以当时的状态建立新的备份。

## 什么时候可能有效

Linux 内核将 `tcp_wmem` 的第三项定义为 TCP 自动调优发送缓冲区的上限。应用显式设置 `SO_SNDBUF` 时，该连接的发送缓冲区自动调优会被关闭，本参数可能不再决定它的大小。参见 [Linux 内核 IP sysctl 文档中的 tcp_wmem](https://docs.kernel.org/networking/ip-sysctl.html#tcp-wmem)。

在真实传输期间，`ss -tin` 中持续增加的 `sndbuf_limited` 可以作为进一步检查发送缓冲区限制的线索。应结合该连接的 RTT、重传、接收窗口、CPU 和内存情况判断，并用相同源、相同方向和相同时长进行修改前后对照。

32 MiB 是自动调优上限，不会在设置时立即为每个连接分配 32 MiB；多条活跃连接仍可能增加实际内存占用。小内存 VPS 应观察可用内存和内存压力，发现负面影响时回滚。

套餐限速、源站限速、跨网拥塞、本地网络、CPU 饱和或接收端限制，都可能继续限制速度。UDP/QUIC 数据传输不受这个 TCP 参数直接控制；经过 CDN 时，它只影响由这台 VPS 负责发送的 TCP 连接段。

## 已有验证与兼容性

已在 **Ubuntu 24.04** 上完成真实 VPS 的调整与测速验证。以下为一次匿名的同源、同方向单流对照，采用 A → B → A → B 顺序：

| 顺序 | 发送缓冲区最大值 | 实测速度 |
| --- | --- | --- |
| A：修改前 | 4 MiB | 15.34 MB/s |
| B：提高上限 | 32 MiB | 49.01 MB/s |
| A：恢复原值 | 4 MiB | 15.17 MB/s |
| B：再次提高 | 32 MiB | 40.76 MB/s |

该测试中，原值下出现发送缓冲区限制，提高上限后相关限制消失。结果说明这条连接受益于调整，不能当作其他服务器的速度承诺，也不能用不同测试源之间的差异计算提速幅度。表中的 MB/s 按十进制字节计速；缓冲区大小的 MiB 按二进制计量。

其他 Linux 发行版只有满足依赖后的兼容性预期，未在这里宣称完成真实网络环境验证。自动化测试或 CI 通过，验证的是脚本行为，不代表已经验证某个发行版上的公网吞吐或重启行为。

## 官方资料

- [Linux 内核：IP sysctl / tcp_wmem](https://docs.kernel.org/networking/ip-sysctl.html#tcp-wmem)
- [systemd：sysctl.d 配置格式、目录优先级与文件顺序](https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html)
- [systemd：systemd-sysctl 服务](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysctl.service.html)
