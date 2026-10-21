# Android 模拟器 Docker / K8s 部署

本目录部署一个 Android 模拟器及 BoltzLog APK，提供集群内远程 ADB。它不包含 Python 测试服务、Maestro、Appium、评测控制台或业务后端；这些程序可作为独立服务连接本模拟器。

设备参照当前本机配置：Android 15 / API 35 / Google APIs / x86_64、Pixel 6、4 核、2048 MB、10 GB userdata、512 MB SD 卡、Asia/Shanghai。Linux 内重新创建 AVD，不复制 Windows 的 SDK、快照、登录态或整个 AVD 目录。云端采用无窗口软件 GPU，CPU 使用 KVM；ADB 截图和 UI 自动化仍可使用。

## 文件与启动契约

| 文件 | 用途 |
| --- | --- |
| `Dockerfile.base` | 安装 Linux Android SDK、模拟器、API 35 系统镜像和 JRE；基础镜像示例标识 `android-emulator-base:api35-v1` |
| `Dockerfile` | 复制 APK 和脚本；应用镜像示例标识 `android-emulator:api35-app-v1` |
| `start-emulator.sh` | 镜像内启动入口，启动 ADB、模拟器，等待系统开机，安装并打开 APK |
| `healthcheck.sh` | 启动、存活、就绪检查 |
| `k8s/base/deployment.yaml` | 默认临时设备：Namespace、Deployment、ClusterIP Service、NetworkPolicy |
| `k8s/persistent/` | 可选保留设备状态的 PVC 覆盖配置 |

启动由 `Dockerfile` 的 `ENTRYPOINT` / `CMD` 确定。Pod 容器未配置 `command` / `args`；YAML 中探针的 `exec.command` 只执行健康检查，不覆盖启动入口。未写节点亲和性、nodeSelector、污点容忍。

## 构建与发布

在本目录作为构建上下文执行，避免把项目凭据、测试报告或 Windows AVD 发给构建器。需要 Linux amd64 构建环境；在 Windows 上可使用能构建 Linux 镜像的构建器，但真正启动模拟器需在有 KVM 的 Linux 节点完成。

本次已把 `D:\downloads\composeApp-debug(3).apk` 复制为 `app/app.apk`。更新 App 时替换此文件；如果单独复制部署文本文件到另一台机器，需同时传入 APK：

```powershell
Set-Location 'D:\Projects\自动化测试\deploy\android-emulator'
Copy-Item -LiteralPath 'D:\downloads\composeApp-debug(3).apk' -Destination '.\app\app.apk'
```

以下为构建机 Bash 命令。把 `registry.example.com/testing` 替换为你的镜像仓库，先完成仓库登录：

```bash
# 首次或升级 SDK/模拟器时构建。构建阶段下载 Google Android SDK 包。
docker build --platform linux/amd64 -f Dockerfile.base \
  -t registry.example.com/testing/android-emulator-base:api35-v1 .
docker push registry.example.com/testing/android-emulator-base:api35-v1

# 常规 APK / 脚本更新只执行这一段。
docker build --platform linux/amd64 -f Dockerfile \
  --build-arg BASE_IMAGE=registry.example.com/testing/android-emulator-base:api35-v1 \
  -t registry.example.com/testing/android-emulator:api35-app-v1 .
docker push registry.example.com/testing/android-emulator:api35-app-v1
```

基础镜像固定了 CLI 压缩包版本及 SHA-256；SDK 包通过指定的包 ID 获取当前稳定版本，因此重新构建基础镜像可能得到新版本。实际安装清单保存在镜像 `/opt/android-sdk-packages.txt`。上线时用独立、不可覆写的版本标签，最好将 `BASE_IMAGE` 和部署 `image` 固定为仓库推送后返回的 digest。基础镜像升级用 `api35-v2`，普通 APK 升级用 `api35-app-v2`，避免覆盖旧标签。

Dockerfile 使用所固定 CLI 包自带的 `sdkmanager` / `avdmanager`，不依赖未来 CLI 命令迁移。更换 CLI 下载版本时，必须同步更新其 SHA-256。

Linux 单机试运行（不会覆盖镜像启动命令）：

```bash
docker run --rm --name android-emulator --device /dev/kvm --shm-size=1g \
  -p 127.0.0.1:15037:5037 \
  registry.example.com/testing/android-emulator:api35-app-v1
```

## K8s 部署

先修改 `k8s/base/deployment.yaml` 的镜像地址。私有仓库按现有集群方案配置镜像拉取凭据。

默认使用临时设备：

```bash
kubectl apply -k k8s
kubectl -n android-testing rollout status deployment/android-emulator --timeout=1000s
kubectl -n android-testing logs -f deployment/android-emulator
```

需要保留登录态、App 本地数据或设备相册时，**首次部署前选择** PVC 版本：

```bash
# 先确认 pvc.yaml 使用的默认 StorageClass 是云块存储 CSI，或填写 storageClassName。
kubectl apply -k k8s/persistent
kubectl -n android-testing get pvc
kubectl -n android-testing rollout status deployment/android-emulator --timeout=1000s
```

两种配置选择一种持续维护，不要交替 apply。PVC 版本使用同一 Deployment、单副本和 Recreate，不能直接扩成多副本共享一个 AVD。要求一块盘只由一个模拟器写入；有 CSI 支持时可把 PVC 的访问模式改为 `ReadWriteOncePod`。多设备需各自独立的工作负载、卷、Service 和调度/会话分配，不可直接将此 Service 后面的 replicas 调大，否则多条 ADB TCP 连接可能落到不同设备。

默认 `emptyDir` 随容器重启保留，但 Pod 被删除、重建或迁移后会丢失。PVC 版本也必须有备份，云盘不是备份。要防止删 PVC 后云盘被回收，应使用 `reclaimPolicy: Retain` 的 StorageClass，或显式调整已绑定 PV 的回收策略；这是集群存储配置，不由本目录创建。

运行时挂载 `/dev/kvm`；仅开启嵌套虚拟化还需节点实际存在这个字符设备。本 YAML 采用 `privileged: true`，因为普通 hostPath 挂载不保证容器设备 cgroup 允许 KVM；它授予较高节点权限，需节点/namespace 策略允许。集群已安装 KVM device plugin 时，可改为请求该插件真实的扩展资源并移除 privileged，不要凭空填写一个资源名。此处不添加你负责的节点调度规则。

## 远程 ADB 与测试程序

服务地址为 `android-emulator.android-testing.svc.cluster.local:5037`，这里是 **ADB server**。使用 `-H` / `-P`，不要执行 `adb connect ...:5037`：

```bash
adb -H android-emulator.android-testing.svc.cluster.local -P 5037 devices -l
adb -H android-emulator.android-testing.svc.cluster.local -P 5037 \
  -s emulator-5554 shell getprop sys.boot_completed
```

NetworkPolicy 默认仅允许同一 namespace 中带 `android-adb-client: "true"` 标签的测试 Pod 访问 5037；为测试工作负载的 Pod template 设置该标签。策略生效依赖 CNI 支持 NetworkPolicy。ADB server 不提供应用级鉴权，不能用公网 LoadBalancer/Ingress 直接暴露。

本地临时调试：

```bash
kubectl -n android-testing port-forward service/android-emulator 15037:5037
# 在另一个终端
adb -H 127.0.0.1 -P 15037 devices -l
```

测试程序与镜像尽量使用同一版 Android platform-tools，防止 ADB 版本冲突导致重启远程 server。这里仅提供远程 ADB，不承诺跨 Pod 的完整 Appium/Maestro 链路：Appium 的 UiAutomator2 等驱动还涉及端口转发，可将 Appium 放在同一 Pod 内连接本地 ADB，或另行配置并验证驱动转发端口的路由。其他工具若只支持本地 ADB，也需先验证其远程 ADB 能力；不能把此地址当作普通 Android adbd 端口。不要通过测试程序启动第二个 AVD。

Service readiness 代表系统已启动、APK 安装及首次 Activity 启动成功；不代表业务登录或后端可用。探针后续检查 Android/ADB 响应，不要求 App 始终前台，避免干扰测试切换页面或应用。

## 无状态边界及不能丢失的数据

默认方案是“设备可重建”，不保证在途测试能跨 Pod 重启继续。它不将既有有状态测试系统自动变成无状态。当前用例涉及相册和登录，若这些数据没有外部原件和自动初始化流程，就应选择 PVC 版本。

| 数据 | 能否丢失 | 推荐保存位置与方式 |
| --- | --- | --- |
| APK、基础镜像、部署文件、测试代码和用例 | 发布/重建所需版本不能丢 | 镜像仓库保留版本及 digest；APK 原始产物保存对象存储/制品库；代码和清单纳入 Git |
| 相册测试视频、图片原件 | 作为唯一副本时绝不能丢 | 对象存储保存原件及校验值；设备内仅留可重放入库的副本。当前启动脚本不自动下载或导入媒体 |
| App 登录态、离线记录、未上传媒体、设备内数据库/文件和 Android Keystore | 无外部副本或无法重新登录时不能丢 | 使用 PVC 将整个 `/data` 放到云块存储；含 AVD 磁盘、SD 卡、Android 用户目录及 ADB key。定期停机快照；对象存储不能直接作为运行中的 AVD 随机写磁盘 |
| 已上传业务记录、账号、资产元数据 | 不能丢 | 由现有业务后端数据库和对象存储持久化及备份；本模拟器没有这些后端数据库，不新建一个空数据库代替它们 |
| 测试任务状态、结果、写操作是否已发生、去重标识 | 需要可靠恢复时不能丢 | 测试执行服务落外部数据库；本模拟器不实现任务调度、事务或业务操作去重 |
| 截图、录屏、XML、logcat 和测试报告 | 作为验收/排障证据需要保留 | 测试执行器及时上传对象存储；结构化索引和结果进数据库；未上传前删除 Pod 仍会丢，本镜像不内置自动上传器 |
| 模拟器控制台日志 | 审计或排障要求范围内不能丢 | 输出 stdout/stderr，由集群日志采集器送日志平台/对象存储；`kubectl logs` 不等于持久化 |
| AVD 缓存、可重建安装包、可再次登录的会话、已在对象存储的媒体副本 | 可按测试要求丢弃 | 默认 `/data` 临时盘，无需 PVC；`/dev/shm` 始终临时 |
| 测试账号密码、API key | 凭据本身需安全托管 | 云 Secret Manager 或现有 K8s Secret 管理流程；不写入 Dockerfile、APK 附加文件或 YAML 明文。登录态不烘焙进镜像 |

严格无状态使用前提：测试执行器每次启动都能重新登录、下载并导入固定媒体、从外部存储恢复任务输入，并及时上传结果。这些业务初始化不在本镜像中伪造实现。

## 升级、备份与恢复注意事项

1. 普通 APK 更新只重建应用镜像并修改 YAML image。启动时 `adb install -r` 保留 PVC 内的 App 数据。签名不一致或降级安装失败会明确报错，不自动卸载或清数据；App 自身升级数据库的迁移行为由 APK 决定。
2. PVC 模式升级前暂停任务并把 Deployment 缩到 0，确认 Pod 已终止，制作云盘快照；恢复副本后再更新 APK。停机快照优于在线复制正在写入的 qcow2/数据库文件。
3. 系统镜像或模拟器版本改变时，启动脚本会通过镜像身份校验拒绝直接复用旧卷。优先使用新卷并重新初始化；需要迁移时先停机备份，在副本卷中验证，不自动覆盖原盘或移除校验标记。
4. 从临时盘切到 PVC 不会自动迁移旧 Pod 数据；必须在旧 Pod 删除前导出需保留的文件，或重新登录/导入原件。当前 Windows AVD 数据也不会自动迁移到 Linux 云盘。
5. Pod 意外重建后在途业务操作的结果可能不确定。测试执行器应先核对服务端结果，不自动重放发送消息、上传、生成等写操作。
6. 云端默认使用 Pod 出网，不继承本机 VPN、代理或 IPv6 修改。如果后端只能经专网访问，应配置节点/集群网络。确需代理时设置 `EMULATOR_HTTP_PROXY`，指定 DNS 时设置 `EMULATOR_DNS_SERVERS`；不要填 Windows 的 `127.0.0.1`。不默认屏蔽云端 IPv6。

## 参考与验证范围

- [Android Emulator 容器与 KVM](https://github.com/google/android-emulator-container-scripts)
- [Android 软件 GPU 与硬件加速](https://developer.android.com/studio/run/emulator-acceleration)
- [ADB server 与设备端口](https://developer.android.com/tools/adb)
- [K8s emptyDir 与 hostPath](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Android CLI 下载及校验值](https://developer.android.com/studio#command-line-tools-only)

已通过两份脚本的 `bash -n` 语法检查；两种 Kustomize 配置分别渲染出 4 和 5 个资源，已核对启动命令未被覆盖、无节点调度规则、临时盘/PVC 挂载正确。UTF-8 检查通过。已用 `aapt` 核对 APK 的包名、MainActivity 与 x86_64 支持，复制前后 SHA-256 一致：`7f3811261d67e5e9fe3325dc25b5d02e4f7d239d2fcacd0d282840e9455a3edf`。

当前本机 Docker Linux daemon 未运行，未实际构建镜像或在目标 K8s 节点启动；首次部署还需验证 SDK 下载、KVM、APK 冷启动、远程 ADB、网络访问以及所选云盘 CSI 行为。
