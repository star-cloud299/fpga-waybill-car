# 将本项目上传到 GitHub：逐步操作

本地已整理好 `github_upload/fpga-waybill-car`，这是要上传的代码目录。原工程没有修改。`github_upload/release_assets` 是要另挂在 Releases 的附件目录，不要把整个 Fpga111 拖进仓库。

## 1. 登录 GitHub 和 GitHub Desktop

打开 https://github.com/ 注册/登录自己的账号。再从 https://desktop.github.com/ 安装 GitHub Desktop，启动后选择 **Sign in to GitHub.com**，在浏览器完成授权。账号密码和验证码只在 GitHub 自己的页面输入，不需要发给助手。

首次设置 Git 时填写自己的名称和邮箱；如果不想公开真实邮箱，可以使用 GitHub Settings → Emails 中显示的 noreply 邮箱。

## 2. 把整理好的本地仓库加入 Desktop

本目录已经仅在本地执行了 Git 初始化，还没有创建远程仓库或上传。

1. GitHub Desktop 左上角选择 **File → Add local repository…**。
2. 点击 **Choose…**，选择：

```text
C:\Users\LENOVO\Desktop\Fpga111\github_upload\fpga-waybill-car
```

3. 点击 **Add repository**。不要选择 Fpga111 根目录，也不要选择 release_assets。
4. 左侧 **Changes** 应看到 README、versions、docs、.gitignore 等待提交文件。
5. 确认列表没有 `.venv`、旧整包 ZIP、大批实拍或 `.Xil`。
6. 左下 **Summary** 填写：`Import PC v1 and retained car v2 projects`。
7. 点击 **Commit to main**。若名称/邮箱未设置，按提示完成本地 Git 身份配置。

## 3. 发布到 GitHub

1. 点击上方 **Publish repository**。
2. **Name**：建议 `fpga-waybill-car`。
3. **Description**：`FPGA-based waybill image processing and mobile verification car`。
4. **Keep this code private**：建议首次保留勾选，团队检查完再决定是否公开；若希望任何人都可访问，则取消勾选。此选项由你决定。
5. **Organization**：个人仓库选自己的账号/None。
6. 点击 **Publish repository**，等待上传结束。
7. 选择 **Repository → View on GitHub** 打开网页。
8. 页面应能看到 README，以及 `versions/v1_pc`、`versions/v2_car`。打开文件确认源码可在线阅读。

## 4. 把完整包和固件放到 Releases

普通 Git 单文件上限为 100 MiB；网页 Add file 上传单文件上限为 25 MiB。第一版原 ZIP 约 100.2 MiB，使用 Releases 附件上传。Release 单个附件须小于 2 GiB，当前两个包符合。

### 第一版

1. 仓库网页右侧点击 **Releases**；首次可能显示 **Create a new release**，否则点 **Draft a new release**。
2. **Choose a tag** 输入 `v1.0-pc`，选择 **Create new tag**；**Target** 选择 `main`。
3. **Release title** 填 `V1.0 电脑联机图像处理版`。
4. 描述复制仓库 `docs/RELEASE_V1.md` 的正文；注意这次初始导入中两个版本目录共存，V1 入口是 `versions/v1_pc`。
5. 在页面底部附件区选择：

```text
github_upload/release_assets/waybill_complete_final_20261026.zip
github_upload/release_assets/SHA256SUMS.txt
```

6. 等附件上传完成，再点 **Publish release**。

### 智能车版

按同样步骤再建一次 Release：

- Tag：`v2.0-car`；Target：`main`。
- Title：`V2.0 智能车两段直线版（保留版本）`。
- 描述：复制 `docs/RELEASE_V2.md`。
- 附件：`waybill_car_v2_source_firmware_20261104.zip`、`SHA256SUMS.txt`。
- 由于整条路线仍待验收，可勾选 **This is a pre-release**，在说明里保留当前已知问题。

Release 页面自动出现的 **Source code (zip)** 只是该标签的仓库源码，不包含额外上传的 V2 BIT/MCS。使用固件时下载自己上传的那个发布包。

## 5. 邀请队友

私有仓库中，进入 **Settings → Collaborators / Collaborators and teams → Add people**，输入队友 GitHub 用户名并邀请。队友接受后即可访问；不要把账号密码共用。

队友使用 Desktop 的 **File → Clone repository**，选择仓库并克隆，即可按各版本 README 安装依赖。发布 ZIP 在网页 **Releases → Assets** 下载。

## 6. 后续更新

修改整理目录中的源码后，在 Desktop 的 **Changes** 查看差异，填写本次修改说明，点击 **Commit to main → Push origin**。Commit 只是本地保存，Push 才上传到 GitHub。

本上传目录是原工作工程的独立副本。继续在旧工作目录开发时，要把确认需要发布的改动同步到上传目录；它不会自动跟随旧工程变化。上传大规模实拍、缓存、整包 ZIP 前先检查忽略规则。

## 官方操作文档

- GitHub Desktop：https://docs.github.com/en/desktop/overview/creating-your-first-repository-using-github-desktop
- 大文件限制：https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github
- Release 创建：https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository
- Release 附件限制：https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases
