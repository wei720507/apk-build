#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将「一对一绑定 + 老人授权 + 常驻红条通知/一键断开」定制层注入 RustDesk 源码。

用法:
    python3 apply_overlay.py <rustdesk_source_root>

该脚本只做基于唯一锚点的字符串替换，并对每个锚点做存在性断言，
任一锚点未命中即报错退出，避免「静默改错位置」。
注入位置（均已对照 rustdesk master 源码核实）:
  - flutter/lib/models/server_model.dart  添加绑定/授权逻辑
  - flutter/lib/main.dart                启动时应用硬编码私有化配置
  - .../MainActivity.kt                  新增方法通道分支 + 通知「断开」回跳
  - .../MainService.kt                   常驻「正在被远程协助」通知 + 销毁时清除
"""
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
ERR = 0


def patch(path, replacements):
    """replacements: list of (anchor, new_text). 每个 anchor 必须存在且唯一。"""
    global ERR
    full = os.path.join(ROOT, path)
    if not os.path.isfile(full):
        print(f"[FAIL] 找不到文件: {full}")
        ERR += 1
        return
    with open(full, "r", encoding="utf-8") as f:
        s = f.read()
    for anchor, new_text in replacements:
        cnt = s.count(anchor)
        if cnt == 0:
            print(f"[FAIL] 锚点未命中: {path}\n        >>> {anchor[:80]!r}")
            ERR += 1
            return
        if cnt > 1:
            print(f"[WARN] 锚点出现 {cnt} 次(期望1): {path}\n        >>> {anchor[:80]!r}")
        s = s.replace(anchor, new_text, 1)
    with open(full, "w", encoding="utf-8") as f:
        f.write(s)
    print(f"[OK ] 已注入: {path}")


# ---------------------------------------------------------------------------
# 1) server_model.dart —— 一对一绑定 + 老人授权弹窗
# ---------------------------------------------------------------------------
SERVER_MODEL_IMPORT = (
    "import '../mobile/pages/server_page.dart';",
    "import '../mobile/pages/server_page.dart';\n"
    "import 'package:flutter_hbb/custom/secure_binding.dart';",
)

# addConnection 里原本调用默认弹窗，改为走我们的守卫
SERVER_MODEL_ADD_CONN = (
    "      if (isAndroid && !client.authorized) showLoginDialog(client);",
    "      if (isAndroid && !client.authorized) {\n"
    "        elderGuardIncoming(client);\n"
    "      }",
)

# 在 showClientDialog 结束后插入两个方法
SERVER_MODEL_METHODS = (
    "        onSubmit: submit,\n"
    "        onCancel: cancel,\n"
    "      );\n"
    "    }, tag: getLoginDialogTag(client.id));\n"
    "  }",
    "        onSubmit: submit,\n"
    "        onCancel: cancel,\n"
    "      );\n"
    "    }, tag: getLoginDialogTag(client.id));\n"
    "  }\n"
    "\n"
    "  // ===== 一对一绑定 + 老人授权（定制） =====\n"
    "  /// 老人端收到连接请求的总入口：\n"
    "  ///  - 已绑定且非绑定设备 -> 直接拒绝（防外人入侵，不弹窗、不抖动）\n"
    "  ///  - 首次/已绑定且匹配 -> 弹老人授权弹窗\n"
    "  Future<void> elderGuardIncoming(Client client) async {\n"
    "    final bound = BindingStore.getBoundPeer();\n"
    "    if (bound != null && bound != client.peerId) {\n"
    "      sendLoginResponse(client, false); // 陌生人：直接拒绝\n"
    "      return;\n"
    "    }\n"
    "    final accepted = await showElderAuthDialog(client);\n"
    "    if (accepted) {\n"
    "      if (bound == null) {\n"
    "        BindingStore.bind(client.peerId); // 首次连接即锁定一对一\n"
    "      }\n"
    "      sendLoginResponse(client, true);\n"
    "    } else {\n"
    "      sendLoginResponse(client, false);\n"
    "    }\n"
    "  }\n"
    "\n"
    "  /// 老人友好授权弹窗：超大「允许 / 拒绝」按钮，必须本人点。\n"
    "  /// 返回 true=允许，false=拒绝。\n"
    "  Future<bool> showElderAuthDialog(Client client) async {\n"
    "    final completer = Completer<bool>();\n"
    "    final ctx = globalKey.currentContext;\n"
    "    if (ctx == null) {\n"
    "      completer.complete(false);\n"
    "      return completer.future;\n"
    "    }\n"
    "    showDialog(\n"
    "      context: ctx,\n"
    "      barrierDismissible: false,\n"
    "      builder: (dialogContext) {\n"
    "        void decide(bool v) {\n"
    "          if (!completer.isCompleted) completer.complete(v);\n"
    "          Navigator.of(dialogContext).pop();\n"
    "        }\n"
    "\n"
    "        return AlertDialog(\n"
    "          title: Text(translate('Remote assistance request'),\n"
    "              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),\n"
    "              textAlign: TextAlign.center),\n"
    "          content: Column(\n"
    "            mainAxisSize: MainAxisSize.min,\n"
    "            children: [\n"
    "              const SizedBox(height: 8),\n"
    "              const Text('有人请求远程控制您的手机',\n"
    "                  style: TextStyle(fontSize: 20), textAlign: TextAlign.center),\n"
    "              const SizedBox(height: 12),\n"
    "              ClientInfo(client),\n"
    "              const SizedBox(height: 12),\n"
    "              const Text('请确认是您的家人后再点「允许」',\n"
    "                  style: TextStyle(fontSize: 16, color: Colors.grey),\n"
    "                  textAlign: TextAlign.center),\n"
    "              const SizedBox(height: 18),\n"
    "              SizedBox(\n"
    "                  width: double.infinity,\n"
    "                  child: ElevatedButton(\n"
    "                    style: ElevatedButton.styleFrom(\n"
    "                        padding: EdgeInsets.symmetric(vertical: 16),\n"
    "                        textStyle: const TextStyle(fontSize: 22)),\n"
    "                    onPressed: () => decide(true),\n"
    "                    child: const Text('允许'),\n"
    "                  )),\n"
    "              const SizedBox(height: 12),\n"
    "              SizedBox(\n"
    "                  width: double.infinity,\n"
    "                  child: ElevatedButton(\n"
    "                    style: ElevatedButton.styleFrom(\n"
    "                        padding: EdgeInsets.symmetric(vertical: 16),\n"
    "                        textStyle: const TextStyle(fontSize: 22),\n"
    "                        backgroundColor: Colors.red),\n"
    "                    onPressed: () => decide(false),\n"
    "                    child: const Text('拒绝'),\n"
    "                  )),\n"
    "            ],\n"
    "          ),\n"
    "          actions: const [],\n"
    "        );\n"
    "      },\n"
    "    );\n"
    "    return completer.future;\n"
    "  }\n"
    "  // ===== 定制结束 =====",
)

# 接受连接后：启动「正在被远程协助」常驻通知
SERVER_MODEL_ACCEPT = (
    "      client.authorized = true;\n      notifyListeners();",
    "      client.authorized = true;\n      notifyListeners();\n"
    "      if (isAndroid) parent.target?.invokeMethod(\"start_control_notification\");",
)

# 客户端全部断开后：停止常驻通知
SERVER_MODEL_REMOVE = (
    "        parent.target?.dialogManager.dismissByTag(getLoginDialogTag(id));\n"
    "        parent.target?.invokeMethod(\"cancel_notification\", id);",
    "        parent.target?.dialogManager.dismissByTag(getLoginDialogTag(id));\n"
    "        parent.target?.invokeMethod(\"cancel_notification\", id);\n"
    "        if (isAndroid && _clients.isEmpty) {\n"
    "          parent.target?.invokeMethod(\"stop_control_notification\");\n"
    "        }",
)

# 老人端（isElder）彻底移除「相机扫码」入口（appBar 右上角那个二维码图标）。
# 该按钮本质是 ScanButton() → 打开相机扫码 → 经 SCAN_CAMERA 补丁会 connect() 发起连接，
# 于是老人端也能变成「控制方」，这正是「方向搞反 / 老人机控制了协助机」的根因之一。
# 扫码发起连接的能力只保留给协助端。
SETTINGS_SCAN_GATE = (
    "  final appBarActions = bind.isDisableSettings() ? [] : [ScanButton()];",
    "  final appBarActions = (bind.isDisableSettings() || BindingStore.isElder)\n"
    "      ? [] : [ScanButton()];",
)

# ---------------------------------------------------------------------------
# 1b) settings_page.dart —— 老人端「绑定管理」设置项
# ---------------------------------------------------------------------------
SETTINGS_IMPORT = (
    "import 'scan_page.dart';",
    "import 'scan_page.dart';\n"
    "import 'package:flutter_hbb/custom/secure_binding.dart';\n"
    "import 'package:flutter_hbb/custom/binding_management.dart';",
)

# 在「关于」区块的 Privacy Statement 之后插入「绑定管理」tile（仅老人端显示）
SETTINGS_TILE = (
    "            SettingsTile(\n"
    "              title: Text(translate(\"Privacy Statement\")),\n"
    "              onPressed: (context) =>\n"
    "                  launchUrlString('https://rustdesk.com/privacy.html'),\n"
    "              leading: Icon(Icons.privacy_tip),\n"
    "            )\n"
    "          ],",
    "            SettingsTile(\n"
    "              title: Text(translate(\"Privacy Statement\")),\n"
    "              onPressed: (context) =>\n"
    "                  launchUrlString('https://rustdesk.com/privacy.html'),\n"
    "              leading: Icon(Icons.privacy_tip),\n"
    "            ),\n"
    "            if (BindingStore.isElder)\n"
    "              SettingsTile(\n"
    "                title: const Text('绑定管理（远程协助）'),\n"
    "                value: Padding(\n"
    "                  padding: EdgeInsets.symmetric(vertical: 8),\n"
    "                  child: Text(BindingStore.summaryText()),\n"
    "                ),\n"
    "                onPressed: (context) => showBindingManagementDialog(context),\n"
    "                leading: const Icon(Icons.admin_panel_settings),\n"
    "              ),\n"
    "            if (!BindingStore.isElder)\n"
    "              SettingsTile(\n"
    "                title: const Text('已绑定的老人机'),\n"
    "                value: Padding(\n"
    "                  padding: EdgeInsets.symmetric(vertical: 8),\n"
    "                  child: Text(BindingStore.elderSummaryText()),\n"
    "                ),\n"
    "                onPressed: (context) => showBindingManagementDialog(context),\n"
    "                leading: const Icon(Icons.admin_panel_settings),\n"
    "              )\n"
    "          ],",
)

# ---------------------------------------------------------------------------
# 2) main.dart —— 启动时应用私有化配置
# ---------------------------------------------------------------------------
MAIN_IMPORT = (
    "import 'common.dart';",
    "import 'common.dart';\n"
    "import 'package:flutter_hbb/custom/hardconfig.dart';",
)

MAIN_CALL = (
    "void runMobileApp() async {\n  await initEnv(kAppTypeMain);",
    "void runMobileApp() async {\n  await initEnv(kAppTypeMain);\n"
    "  await applyHardcodedConfig();",
)

# ---------------------------------------------------------------------------
# 3) MainActivity.kt —— 方法通道分支 + 通知「断开」回跳
# ---------------------------------------------------------------------------
ACT_IMPORT = (
    "class MainActivity : FlutterActivity() {",
    "class MainActivity : FlutterActivity() {\n"
    "    override fun onNewIntent(intent: Intent) {\n"
    "        super.onNewIntent(intent)\n"
    "        if (intent.action == \"com.carriez.flutter_hbb.ELDER_DISCONNECT\") {\n"
    "            mainService?.destroy()\n"
    "            flutterMethodChannel?.invokeMethod(\"elder_disconnect_request\", null)\n"
    "        }\n"
    "    }",
)

ACT_BRANCH = (
    "                \"cancel_notification\" -> {\n"
    "                    if (call.arguments is Int) {\n"
    "                        val id = call.arguments as Int\n"
    "                        mainService?.cancelNotification(id)\n"
    "                    } else {\n"
    "                        result.success(true)\n"
    "                    }\n"
    "                }",
    "                \"cancel_notification\" -> {\n"
    "                    if (call.arguments is Int) {\n"
    "                        val id = call.arguments as Int\n"
    "                        mainService?.cancelNotification(id)\n"
    "                    } else {\n"
    "                        result.success(true)\n"
    "                    }\n"
    "                }\n"
    "                \"start_control_notification\" -> {\n"
    "                    mainService?.startControlNotification()\n"
    "                    result.success(null)\n"
    "                }\n"
    "                \"stop_control_notification\" -> {\n"
    "                    mainService?.stopControlNotification()\n"
    "                    result.success(null)\n"
    "                }",
)

# ---------------------------------------------------------------------------
# 4) MainService.kt —— 常驻红条通知 + 销毁时清除
# ---------------------------------------------------------------------------
SVC_CANCEL = (
    "    fun cancelNotification(clientID: Int) {\n"
    "        notificationManager.cancel(getClientNotifyID(clientID))\n"
    "    }",
    "    fun cancelNotification(clientID: Int) {\n"
    "        notificationManager.cancel(getClientNotifyID(clientID))\n"
    "    }\n"
    "\n"
    "    private val CONTROL_NOTIFY_ID = 2\n"
    "    fun startControlNotification() {\n"
    "        val disconnectIntent = Intent(this, MainActivity::class.java).apply {\n"
    "            action = \"com.carriez.flutter_hbb.ELDER_DISCONNECT\"\n"
    "            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)\n"
    "        }\n"
    "        val pi = PendingIntent.getActivity(\n"
    "            this, 9901, disconnectIntent,\n"
    "            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE\n"
    "        )\n"
    "        val builder = NotificationCompat.Builder(this, \"RustDesk\")\n"
    "            .setOngoing(true)\n"
    "            .setSmallIcon(R.mipmap.ic_stat_logo)\n"
    "            .setContentTitle(\"\\u26A0 正在被远程协助\")\n"
    "            .setContentText(\"点击「断开」可立即结束远程控制\")\n"
    "            .setPriority(NotificationCompat.PRIORITY_HIGH)\n"
    "            .addAction(\n"
    "                android.R.drawable.ic_menu_close_clear_cancel,\n"
    "                \"断开\",\n"
    "                pi\n"
    "            )\n"
    "        notificationManager.notify(CONTROL_NOTIFY_ID, builder.build())\n"
    "    }\n"
    "\n"
    "    fun stopControlNotification() {\n"
    "        notificationManager.cancel(CONTROL_NOTIFY_ID)\n"
    "    }",
)

SVC_DESTROY = (
    "        stopForeground(true)",
    "        stopForeground(true)\n"
    "        stopControlNotification()",
)

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 1c) remote_page.dart —— 老板端顶部「绑定状态条」+ 连接成功自动绑定
# ---------------------------------------------------------------------------
REMOTE_IMPORT = (
    "import '../widgets/custom_scale_widget.dart';",
    "import '../widgets/custom_scale_widget.dart';\n"
    "import 'package:flutter_hbb/custom/secure_binding.dart';\n"
    "import 'package:flutter_hbb/custom/binding_management.dart';",
)

# 进入远程界面（连接成功）：仅当尚未绑定老人机时，弹「确认绑定」对话框（防误连），
# 确认后才建立一对一绑定；已绑定时不再弹窗。老人端不触发。
REMOTE_INIT = (
    "    super.initState();",
    "    super.initState();\n"
    "    if (!BindingStore.isElder && BindingStore.getBoundElderPeer() == null) {\n"
    "      WidgetsBinding.instance.addPostFrameCallback((_) {\n"
    "        if (context.mounted) {\n"
    "          confirmBindElderDialog(context, widget.id, notifyElderBindChanged);\n"
    "        }\n"
    "      });\n"
    "    }",
)

# 在 body 外包一层状态条（仅老板端显示，老人端直接返回原 child）
REMOTE_BODY = (
    "          body: Obx(",
    "          body: helperBindingBanner(widget.id, Obx(",
)

# 给 helperBindingBanner(...) 补上闭合括号（build 方法结束处）
REMOTE_END = (
    "          )),\n    );\n  }\n\n  Widget getRawPointerAndKeyBody(Widget child) {",
    "          )),\n          ),\n    );\n  }\n\n  Widget getRawPointerAndKeyBody(Widget child) {",
)

# ---------------------------------------------------------------------------
# 5) home_page.dart —— 老人端(elder)隐藏连接页/聊天页 + 引入 BindingStore
# ---------------------------------------------------------------------------
# elder 端不需要 ConnectionPage（远程ID输入框）和 ChatPage（消息），
# 只需 ServerPage（显示 ID + 二维码）+ SettingsPage。
# 通过 BindingStore.isElder 条件跳过这些页面。
# 同时补上 secure_binding.dart 的 import（Dart 不传递 import）。
HOME_IMPORT = (
    "import 'connection_page.dart';",
    "import 'connection_page.dart';\n"
    "import 'scan_page.dart';\n"
    "import 'package:flutter_hbb/custom/secure_binding.dart';",
)

# 控制端(helper)主界面加「扫一扫」悬浮按钮：扫码老人机直连 URI 即发起连接
HOME_FAB = (
    "          body: _pages.elementAt(_selectedIndex),",
    "          floatingActionButton: BindingStore.isElder\n"
    "              ? null\n"
    "              : FloatingActionButton(\n"
    "                  onPressed: () => Navigator.push(\n"
    "                    context,\n"
    "                    MaterialPageRoute(builder: (context) => ScanPage()),\n"
    "                  ),\n"
    "                  tooltip: '扫一扫连接老人机',\n"
    "                  child: const Icon(Icons.qr_code_scanner),\n"
    "                ),\n"
    "          body: _pages.elementAt(_selectedIndex),",
)

HOME_CONN_PAGE = (
    "if (!bind.isIncomingOnly())",
    "if (!bind.isIncomingOnly() && !BindingStore.isElder)",
)

# 修复：elder 端必须保留 ServerPage（二维码在此页面内），
# 只隐藏 ChatPage。原版把整块 if 都藏了导致老人端只剩 SettingsPage。
HOME_CHAT_SERVER = (
    "if (isAndroid && !bind.isOutgoingOnly())",
    "if (isAndroid && (!bind.isOutgoingOnly() || BindingStore.isElder))",
)

# 在 addAll 内部按角色过滤：elder 跳过 ChatPage，保留 ServerPage
HOME_SKIP_CHAT = (
    "_pages.addAll([ChatPage(type: ChatPageType.mobileMain), ServerPage()]);",
    "_pages.addAll([if (!BindingStore.isElder) ChatPage(type: ChatPageType.mobileMain), ServerPage()]);",
)

# ---------------------------------------------------------------------------
# 6) server_page.dart —— 老人端主界面显示二维码
# ---------------------------------------------------------------------------
# 注意：master 的 server_page.dart 没有 `import 'scan_page.dart';`，
# 而是 `import 'home_page.dart';`，故以此为锚点，并补 secure_binding 的 import。
SERVER_QR_IMPORT = (
    "import 'home_page.dart';",
    "import 'home_page.dart';\n"
    "import 'package:flutter_hbb/custom/elder_qr_code.dart';\n"
    "import 'package:flutter_hbb/custom/secure_binding.dart';",
)

# 在 ServerInfo / ServiceNotRunningNotification 之后、ConnectionManager 之前插入二维码
SERVER_QR_WIDGET = (
    "        const ConnectionManager(),",
    "        if (BindingStore.isElder) const ElderQRCode(),\n"
    "        const ConnectionManager(),",
)

# ---------------------------------------------------------------------------
# 7) pubspec.yaml —— qr_flutter 依赖
#    RustDesk master 已自带 qr_flutter: ^4.1.0，无需注入，避免重复键。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 8) scan_page.dart —— 相机扫码支持 rustdesk:// URI 直连
#    原版相机扫码只认 config= 开头（服务器配置），其他一律 "Invalid QR code"。
#    但同文件的「从相册选图」路径已支持 rustdesk:// → handleUriLink。
#    补丁让相机扫码也走 handleUriLink，这样扫老人机二维码就能直连。
# ---------------------------------------------------------------------------
SCAN_CAMERA = (
    "        showServerSettingFromQr(scanData.code!);",
    "        final code = scanData.code!;\n"
    "        if (code.startsWith(bind.mainUriPrefixSync())) {\n"
    "          handleUriLink(uriString: code);\n"
    "        } else if (code.startsWith('RDCDIRECT|')) {\n"
    "          // 老人机直连二维码：提取地址+密码，直接调用连接 API\n"
    "          // （不走 handleUriLink，因为它不从 URI 提取密码 → password=null → 移动端静默卡住）\n"
    "          final parts = code.split('|').skip(1).where((e) => e.isNotEmpty).toList();\n"
    "          String? pwd;\n"
    "          final addrs = <String>[];\n"
    "          for (final p in parts) {\n"
    "            if (p.startsWith('pwd=')) {\n"
    "              pwd = p.substring(4);\n"
    "            } else {\n"
    "              addrs.add(p);\n"
    "            }\n"
    "          }\n"
    "          if (addrs.isNotEmpty) {\n"
    "            final target = addrs.first;\n"
    "            ScaffoldMessenger.of(context).showSnackBar(\n"
    "              SnackBar(content: Text('正在直连 $target …'), duration: const Duration(seconds: 8)),\n"
    "            );\n"
    "            Future.delayed(Duration.zero, () {\n"
"              connect(context, target, password: pwd);\n"
    "            });\n"
    "          } else {\n"
    "            showServerSettingFromQr(code);\n"
    "          }\n"
    "        } else {\n"
    "          showServerSettingFromQr(code);\n"
    "        }",
)

if __name__ == "__main__":
    patch("flutter/lib/models/server_model.dart", [
        SERVER_MODEL_IMPORT,
        SERVER_MODEL_ADD_CONN,
        SERVER_MODEL_METHODS,
        SERVER_MODEL_ACCEPT,
        SERVER_MODEL_REMOVE,
    ])
    patch("flutter/lib/main.dart", [
        MAIN_IMPORT,
        MAIN_CALL,
    ])
    patch(
        "flutter/lib/mobile/pages/settings_page.dart",
        [SETTINGS_IMPORT, SETTINGS_TILE, SETTINGS_SCAN_GATE],
    )
    patch(
        "flutter/lib/mobile/pages/remote_page.dart",
        [REMOTE_IMPORT, REMOTE_INIT, REMOTE_BODY, REMOTE_END],
    )
    patch(
        "flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainActivity.kt",
        [ACT_IMPORT, ACT_BRANCH],
    )
    patch(
        "flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt",
        [SVC_CANCEL, SVC_DESTROY],
    )
    # 老人端简化主界面（隐藏连接页/聊天页 + 引入 BindingStore + 控制端扫码FAB）
    patch("flutter/lib/mobile/pages/home_page.dart", [
        HOME_IMPORT,
        HOME_CONN_PAGE,
        HOME_CHAT_SERVER,
        HOME_SKIP_CHAT,
        HOME_FAB,
    ])
    # 老人端 ServerPage 加二维码
    patch(
        "flutter/lib/mobile/pages/server_page.dart",
        [SERVER_QR_IMPORT, SERVER_QR_WIDGET],
    )
    # 控制端扫码支持 rustdesk:// URI 直连
    patch("flutter/lib/mobile/pages/scan_page.dart", [SCAN_CAMERA])

    if ERR > 0:
        print(f"\n[ABORT] 有 {ERR} 处注入失败，请检查锚点是否与当前 RustDesk 版本一致。")
        sys.exit(1)
    print("\n[DONE] 所有定制层注入成功。")
