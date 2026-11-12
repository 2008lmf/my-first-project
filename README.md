# my-first-project

> 第一个 GitHub 项目，从一个干净、可维护的起点开始。

## 这是什么

一个最小的项目骨架：`README` + `LICENSE` + `.gitignore` + 一键发布脚本。
把你要做的东西放进这个目录，执行一条命令就能上线。

## 快速开始

```powershell
# 1. 看一眼有哪些文件
ls

# 2. 放你的代码进来（或用这里的骨架直接发布）

# 3. 发布到 GitHub
.\publish.ps1 -RepoName my-first-project
```

脚本会做完这几件事：`git init` → 校验 token → 建远端仓库 → 关联 `origin`
→ 提交 → 推送，最后打印仓库地址。

指定仓库名和可见性：

```powershell
.\publish.ps1 -RepoName my-first-project -Visibility public -Description "我的第一个项目"
```

## 目录结构

```
.
├── README.md          # 你现在看的这份
├── LICENSE            # MIT
├── .gitignore         # 屏蔽构建产物、依赖、密钥
├── .gitattributes     # 换行符统一（跨平台克隆不炸 diff）
└── publish.ps1        # 一键发布脚本
```

## 后续日常提交

```powershell
git add -A
git commit -m "feat: 做了什么"
git push
```

首次 `git push` 会弹出 Git Credential Manager 的登录窗口，登录一次以后就记住了。

## 关于 token

`publish.ps1` 用的 Personal Access Token 只在内存里传递，**不会**写进
`.git/config`、不落盘、不进历史。用完可以在 GitHub 设置里随时撤销。

生成地址：<https://github.com/settings/tokens/new>

- classic token：勾 `repo`
- fine-grained token：`Contents: Read and write` + `Administration: Read and write`

## License

[MIT](LICENSE)
