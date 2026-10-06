# Docker 化部署指南（专为斐讯 N1 等 arm64 设备）

本项目在原有"手动装依赖 + 手动配 root 权限 + 手动按顺序起 4 个进程"的基础上，
提供了一套**单容器、一键构建、开箱即用**的 Docker 方案：

- **不再需要**在 N1 上安装 sqlite3 / gcc / Go 等任何环境 —— 全部在镜像构建阶段完成
- **不再需要** root 下到处建 `/run`、`/vol1`、`/var/apps` 目录 —— 全部收在容器内部
- 媒体目录、数据库、音乐数据以卷的方式持久化，容器删了重建数据也在
- 兼容 N1（Amlogic S905，Cortex-A53 armv8.0）：预编译核心经检查按 `GOARM64=v8.0` 基线构建

---

## 一、容器结构说明

```
                     ┌─────────────────── 容器 trimmedia ───────────────────┐
                     │                                                      │
   :8005 ────────────┤  fntv (飞牛影视)  :8005                              │
   :8007 ────────────┤  fnmusic (飞牛音乐) :8007 ── 反代 → trim_music.socket │
                     │      │            │                                  │
                     │      ▼            ▼                                  │
                     │  rpcbroker (伪造飞牛系统服务, 仅 unix socket)          │
                     │  mediasrv  (转码服务, 仅 unix socket, LD_PRELOAD 打桩) │
                     │      ▲                                               │
                     │      └── fntv 通过 /var/run/mediasrv.socket 调用       │
                     │                                                      │
    媒体目录 ────────┤► /vol1/1000      （媒体库，授权目录=一级子目录）        │
                     │  /opt/trim/fntv/data           （影视数据库）→ 卷②     │
                     │  /var/apps/trim.music          （音乐数据）  → 卷③     │
                     └──────────────────────────────────────────────────────┘
```

| 服务 | 端口 | 说明 |
|------|------|------|
| fntv（飞牛影视） | TCP 8005 | Web UI，需 rpcbroker + mediasrv |
| fnmusic（飞牛音乐） | TCP 8007 | Web UI，内置反代，仅需 rpcbroker |
| rpcbroker | 无 | 伪造系统服务层，一切的前提，最先启动 |
| mediasrv | 无 | 转码/媒体分析，供影视调用 |

登录账号：`admin` / `123456`（移植方案自带免登录初始化）

---

## 二、N1 上快速开始（3 步）

### 1. 确认 N1 已装 Docker

```bash
# 检查
docker version && docker compose version

# 如果没有安装（Armbian / Debian 系）：
curl -fsSL https://get.docker.com | sh
# 或者用系统源：
# sudo apt update && sudo apt install -y docker.io docker-compose-plugin
```

> N1 系统要求：**arm64 的 Debian / Ubuntu**（如 Armbian）。内核建议 5.x 及以上。
> OpenWrt 等精简系统理论上也行，但需要自行确保内核支持 docker 与 cgroup，不在本指南覆盖范围。

### 2. 把本项目目录放到 N1 上

把整个项目目录（含 `Dockerfile`、`docker-compose.yml`、`docker/`）传到 N1，例如放到：

```bash
mkdir -p /opt/trimmedia
# 从电脑上传（在电脑端执行）：
# scp -r ./trimmedia-linux-arm root@<N1的IP>:/opt/trimmedia/
cd /opt/trimmedia/trimmedia-linux-arm
```

### 3. 修改媒体目录并启动

编辑 `docker-compose.yml`，把媒体挂载改成你的实际路径：

```yaml
    volumes:
      # ★ 左边改成你的媒体目录（N1 上常见：/mnt/sda1、/mnt/usb、/srv/media 等）
      - /mnt/sda1/media:/vol1/1000
```

然后：

```bash
docker compose up -d --build

# 查看状态（STATUS 列出现 healthy 即正常，首次启动约需 30~60 秒）
docker compose ps
```

首次构建约需 5~15 分钟（取决于网络和 N1 性能，主要在下载约 150MB 资源 + 编译）。

启动后若有异常，先跑一次自检和看日志：

```bash
docker compose run --rm trimmedia check   # 环境自检
docker compose logs -f                    # 实时日志
```

构建/启动正常后访问：

- 影视：`http://<N1的IP>:8005`
- 音乐：`http://<N1的IP>:8007`

---

## 三、国内网络加速

构建阶段需要访问 GitHub 下载 release 资源。如果直连超时，用加速前缀：

```bash
PROXY_PREFIX=https://ghproxy.net/ docker compose build --no-cache
docker compose up -d
```

> 前缀可用镜像自行更换（如 `https://mirror.ghproxy.com/` 等，注意必须是能反向代理
> `github.com/kesry/trimmedia-linux-arm/releases/...` 的服务）。
> 另外建议给 Docker 配一个镜像加速器（`/etc/docker/daemon.json` 的 `registry-mirrors`），
> 拉取基础镜像更快。

#### 进阶：在别的电脑上构建，再导入到 N1

N1 性能有限，也可以在任意装有 Docker 的电脑（x86 也行）上交叉构建：

```bash
# 电脑上（支持 buildx 的 Docker Desktop / Linux Docker）：
git clone <本项目>
cd trimmedia-linux-arm

docker buildx build --platform linux/arm64 \
  --build-arg PROXY_PREFIX=https://ghproxy.net/ \
  -t trimmedia-linux-arm:local --load .

docker save trimmedia-linux-arm:local | gzip > trimmedia-arm64.tar.gz
# 传到 N1 后：
docker load < trimmedia-arm64.tar.gz
cd trimmedia-linux-arm && docker compose up -d
```

#### 进阶二：GitHub Actions 云端构建（★ 强烈推荐给 N1 等小设备）

N1 的 eMMC 空间通常不足以本机构建（构建峰值需要约 2.5GB 空闲空间）。
用 GitHub 免费云端构建，N1 只做"下载 + 加载"（约需 1GB 空间）：

**步骤 1 · 把项目推到你的 GitHub 仓库**（本项目已内置 workflow 文件）：

```bash
cd trimmedia-linux-arm
git init -b main
git add -A
git commit -m "dockerize: add Dockerfile & CI"

# 先在 GitHub 网页创建一个空仓库（建议公开：公共仓库的 arm64 runner 完全免费）
git remote add origin https://github.com/<你的用户名>/trimmedia-linux-arm.git
git push -u origin main
```

**步骤 2 · 等待云端构建**：push 后自动触发（也可在仓库 Actions 页手动 Run）。
约 5~10 分钟，完成后自动创建 Release（tag 形如 `image-1`），附件含
`trimmedia-arm64.tar.gz` 与校验文件。

**步骤 3 · 在 N1 上下载并加载**：

```sh
# 切到空间足够的分区（下载+加载峰值约需 1GB 空闲）
cd /mnt/mmcblk2p4

# 下载（ghproxy 加速；不通则去掉前缀直连，或在电脑浏览器下载后 scp 传过来）
wget "https://ghproxy.net/https://github.com/<你的用户名>/trimmedia-linux-arm/releases/download/image-1/trimmedia-arm64.tar.gz"

# 加载（管道方式，省一半磁盘）
gzip -dc trimmedia-arm64.tar.gz | docker load

# 启动（不需要 --build，compose 直接用已加载的镜像）
cd <项目目录> && docker compose up -d
```

> 更新版本时：重新触发一次 workflow，N1 重复"下载 + load + up -d"三步即可。
> 若 N1 能连通 ghcr.io，也可直接 `docker pull ghcr.io/<用户名>/trimmedia-linux-arm:latest` 后使用。

---

## 四、配置说明（docker-compose.yml）

### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `MEDIA_DIR` | `/vol1/1000` | 媒体库根目录（容器内路径）。**无需修改**，它与挂载点一致即可 |
| `FNTV_WEB_PORT` | `8005` | 影视端口（改了要同步改 ports 映射） |
| `FNMUSIC_WEB_PORT` | `8007` | 音乐端口（同上） |
| `ENABLE_MEDIASRV` | `1` | 转码/媒体分析服务；只玩音乐可设 0 |
| `ENABLE_FNTV` | `1` | 影视开关 |
| `ENABLE_FNMUSIC` | `1` | 音乐开关（N1 内存吃紧时可设 0） |
| `LOG_LEVEL` | `info` | 日志级别 |
| `TZ` | `Asia/Shanghai` | 时区 |

### 数据卷（持久化）

| 卷 | 说明 |
|----|------|
| `/mnt/media:/vol1/1000` | **媒体库**（必配）。可读可写；程序会在其中创建 `default/` 目录 |
| `./data/fntv:/opt/trim/fntv/data` | 影视数据库、元数据。删掉=重置影视库 |
| `./data/music:/var/apps/trim.music` | 音乐数据库、歌词分片库。删掉=重置音乐库 |

> ⚠️ `MEDIA_DIR` 与挂载点务必保持 `/vol1/1000`：程序内部多处硬编码该路径，
> 换成别的容器内路径会走"重建 /vol1 软链接"的分支，容易出问题。

> ⚠️ **OpenWrt / N1 用户特别提醒**：`./data/fntv`、`./data/music` 是相对路径（相对
> `docker-compose.yml` 所在目录）。如果你的项目放在 root 家目录下，数据会写进**根分区**——
> N1 的根分区往往只剩几 MB，会立刻写满报错。请改成大容量分区上的**绝对路径**，如：
>
> ```yaml
>     volumes:
>       - /mnt/mmcblk2p4/trimdata/fntv:/opt/trim/fntv/data
>       - /mnt/mmcblk2p4/trimdata/music:/var/apps/trim.music
> ```
>
> 并先创建目录：`mkdir -p /mnt/mmcblk2p4/trimdata/{fntv,music}`

---

## 五、自检与排障

### 一键自检

```bash
docker compose run --rm trimmedia check
```

输出会列出架构、device-tree、`/dev/dri`、sqlite3、各二进制是否齐全、
动态库解析（重点看 `not found`）、数据卷状态。

### 查看日志

```bash
docker compose logs -f            # 全部
docker compose logs -f trimmedia  # 同上（单容器方案只有一个服务名）
```

### 常见问题

**1. 构建卡在下载资源 / 反复重试**
→ 使用 `PROXY_PREFIX`（见上文"国内网络加速"）。

**2. 打开页面要求初始化 / 登录**
→ 用 `admin` / `123456`。影视首次启动会自动建库播种（日志出现 `database init success`）；
音乐在 `trim-music` 自建 schema 后由启动器播种（约需十几秒）。

**3. 影视里媒体库目录是空的**
→ rpcbroker 把 `MEDIA_DIR` 的**一级子目录**作为授权目录，且每 2 秒自动刷新：
- 直接把电影摆在挂载根目录 → 见到的是"根目录"这个库；
- 想按"电影/电视剧/动漫"分库 → 在媒体目录下建这些子目录，把文件放进去。
另外确认 `docker-compose.yml` 左侧路径确实指向你的硬盘，且容器内可读（root 运行，一般没问题）。

**4. `mediasrv exited with code 1`**
→ 本方案已默认启用 `nodri.so` 打桩（隐藏 `/dev/dri`，避免走 PCI/GPU 枚举崩溃）。
若仍然崩溃，看日志是否与 `/dev/dma_heap` 有关（正常情况下容器看不到它）。
如果自行映射了 `/dev/dri` 又想用 GPU，请去掉打桩——但 N1(S905) 的 GPU 不支持飞牛转码，不建议。

**5. 音乐服务 panic: `unable to open database file`**
→ 多为数据卷里存在半初始化的 `music.db`。清掉音乐数据卷重来：
`docker compose down && rm -rf ./data/music && docker compose up -d`

**6. N1 上卡顿**
→ N1 只有 2GB 内存、USB 2.0 接口（外接硬盘读写上限约 30~40MB/s）：建议只开影视（`ENABLE_FNMUSIC=0`）；
播放尽量选低码率文件，N1 无硬件转码能力（本项目本来就"无转码"，纯 CPU 直接串流为主）。

**7. 端口冲突**
→ 改 `ports` 左边（如 `"18005:8005"`），或修改 `FNTV_WEB_PORT` 两边同步改。

**8. 需要完全重置影视**
→ `docker compose down && rm -rf ./data/fntv && docker compose up -d`

**9. 更新到新版本**
→ 拉取新代码/新 release 后：`docker compose build --no-cache && docker compose up -d`
（数据在卷里，不会丢）

---

## 六、设计说明（与原手动部署的对应关系）

| 原手动部署 | 本 Docker 方案 |
|-----------|---------------|
| `install.sh` apt 装 sqlite3/wget/libzmq5 | 构建阶段完成；运行时镜像只带 sqlite3 + tzdata + ca-certificates |
| `install.sh` wget 下载 4 个 release 资源 | 构建阶段下载并 **sha256 校验**，失败会明确报错 |
| `Makefile` 编译 4 个 Go 启动器（需 Go 1.26+） | builder 阶段用 `golang:1.26-trixie` 编译，产物 arm64 |
| `gcc` 编译 nodri/fakecompat/nodmaheap 打桩库 | builder 阶段编译并放 `mediasrv/stubs/`，**容器启动时**按规则分发（复刻 install.sh 逻辑） |
| root 下创建 `/run`、`/var/apps`、`/vol1` 目录/软链接 | 容器内自动创建，宿主机零污染 |
| 手动 `export MEDIA_DIR=... && ... &` 起 4 个进程 | entrypoint 按 rpcbroker → mediasrv → fntv → fnmusic 顺序启动并监控 |
| systemd / nohup 保活 | Docker `restart: unless-stopped` + 健康检查 |

基础镜像为何用 **Debian 13 (trixie)**：预编译核心最高需要 `GLIBC_2.38`
（实测 `libzmq.so.5` 需要 2.38，`trim-media` 需要 2.34），Debian 12 的 2.36 不够。

---

## 七、许可提醒

容器内打包的 `trim-media`、`trim-music`、`mediasrv` 等预编译二进制为飞牛（fnOS）
及第三方提取版本，**不属于**本项目；请仅用于个人学习研究，遵守原项目 LICENSE（MIT）与相关权利方的要求。
