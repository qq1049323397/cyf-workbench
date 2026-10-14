# CYF 综合工作台 · 网站

单文件网页应用。网站主体就是根目录下的 **`index.html`**（约 2.3 MB），
没有构建步骤、没有后端、没有依赖、不需要 Node。

另外带一个 `RP-Hub-main/`（约 2.5 MB），是「试玩当前卡片」用的运行时，见第四节。

---

## 一、怎么部署

把本仓库的文件放到静态服务器的网站根目录即可。**就这一步，没有第二步。**

```bash
git clone https://github.com/qq1049323397/cyf-workbench.git
# 然后把仓库内容放进 nginx / Apache / Caddy 的网站根目录
```

要求只有三条：

| 要求 | 说明 |
| --- | --- |
| 静态文件服务 | 不需要 PHP / Node / Python 等任何运行时 |
| `index.html` 作为默认文档 | 这样访问域名根路径就能打开 |
| 建议启用 HTTPS | 页面要调外部 AI 接口，部分浏览器功能也要求安全上下文 |

放根目录或子目录都行——`index.html` 是自包含的，不引用任何相对路径资源。

---

## 二、nginx 示例

完整配置见 `deploy/nginx.conf.example`，核心部分：

```nginx
server {
    listen 443 ssl http2;
    server_name 你的域名;

    root /var/www/cyf-workbench;
    index index.html;

    # 文件里已声明 <meta charset="utf-8">，这里再声明一次更保险
    charset utf-8;

    # 2.2MB 的单文件，开压缩后传输量降到约 1/5
    gzip on;
    gzip_types text/html;
    gzip_min_length 1024;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

配好后：

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## 三、怎么更新

网站内容就是那一个 HTML 文件。更新 = 换掉 `index.html`。

本机（工作台源码所在目录）执行：

```bash
bash tools/sync-site.sh
```

这个脚本会把最新的工作台复制成 `index.html`、戳上构建戳、跑一遍发布前检查
（HTTP 下能否正常启动、两个角标对不对），然后提交并推送。
服务器那边再 `git pull` 一次即可生效。

### 顶栏那两个角标

| 角标 | 谁改 | 作用 |
| --- | --- | --- |
| `v1.1.0` | 手改源码里的 `WORKBENCH_VERSION` | 语义版本，表达「这一版加了什么」 |
| `2026.10.14.670f9af` | `sync-site.sh` 自动戳 | 构建戳（日期 + 源码短 sha），**判断线上是不是最新版就靠它** |

构建戳每次同步都会变。**它没变 = 同步没生效。**

> 别手动 `cp` 绕过脚本。手动复制出来的 `index.html` 构建戳会停在 `dev`，
> 而 `sync-site.sh` 会拒绝提交这种版本——绕过它只会让线上更难判断。

---

## 四、「试玩当前卡片」运行时

工作台右侧有个「当前卡 · RP-Hub」标签，会把卡片载入一份真实的 RP-Hub 运行时试玩。

**运行时已经随仓库提供**——就是根目录下的 `RP-Hub-main/`（约 2.5 MB）。
克隆下来直接就能用，不需要额外操作。5 个 CDN 依赖都放在 `RP-Hub-main/vendor/` 里，
所以断网也能试玩。

如果要升级运行时版本，重新生成一次即可：

```bash
bash tools/install-runtime.sh
```

它会从 `index.html` 内部自带的快照里解出 `RP-Hub-main/`，并把 5 个 CDN 依赖抓到本地。
铺完刷新页面即可。

---

## 五、这个页面是什么

面向 RP-Hub 的角色卡制作工作台，浏览器里直接跑：

- **三种卡型**：常规卡 / 制作肉卡 / 流水线肉卡
- **8 万字硬标准**：肉卡正文最低字数门槛，写不够不放行
- **玩法新闸门**：检查玩法是否只属于这张卡，防止套模板
- **关键词五闸门**：审核最关键的一环，检查世界书条目能不能被触发到
- **AI 生图封面**：接生图服务生成封面，提示词强制英文
- **质量审核 / 打包导出**：一键出卡

所有数据存在浏览器本地（IndexedDB / localStorage），不上传任何服务器。
AI 接口的密钥由使用者自己填，也只存在浏览器本地。

---

## 六、说明

- 本仓库**只包含网站本身**，工作台的全部源码就在 `index.html` 里。
- 仓库不含任何密钥、账号或隐私信息。
- 页面不发起任何自有后端的请求——它没有后端。
