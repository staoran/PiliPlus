import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/services/debug_log_service.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class DebugLogsPage extends StatefulWidget {
  const DebugLogsPage({super.key});

  @override
  State<DebugLogsPage> createState() => _DebugLogsPageState();
}

class _DebugLogsPageState extends State<DebugLogsPage> {
  List<DebugLogEntry> logs = [];
  late bool enabled;
  String logsText = '';

  @override
  void initState() {
    super.initState();
    enabled = DebugLogService.enabled;
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    logs = await DebugLogService.readAll();
    logsText = logs.isEmpty ? '' : logs.map((item) => item.toString()).join('\n\n');
    if (mounted) setState(() {});
  }

  Future<void> _copyLogs() async {
    final text = await DebugLogService.exportText();
    Utils.copyText(text.isEmpty ? '暂无调试日志' : text, needToast: false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('复制成功'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _clearLogs() async {
    if (await DebugLogService.clear()) {
      logs = [];
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清空'), duration: Duration(seconds: 1)),
        );
      }
    }
  }

  Future<void> _toggleEnabled() async {
    enabled = !enabled;
    await GStorage.setting.put(SettingBoxKey.enableDebugLog, enabled);
    if (!mounted) return;
    setState(() {});
    SmartDialog.showToast('已${enabled ? '开启' : '关闭'}调试日志');
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('调试日志'),
        actions: [
          IconButton(
            onPressed: _loadLogs,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton(
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: _toggleEnabled,
                child: Text(enabled ? '关闭调试日志' : '开启调试日志'),
              ),
              PopupMenuItem(
                onTap: _copyLogs,
                child: const Text('复制日志'),
              ),
              PopupMenuItem(
                onTap: () => PageUtils.launchURL('${Constants.sourceCodeUrl}/issues'),
                child: const Text('问题反馈'),
              ),
              PopupMenuItem(
                onTap: _clearLogs,
                child: const Text('清空日志'),
              ),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: logs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      enabled ? '暂无调试日志' : '调试日志未开启',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            )
          : Padding(
              padding: EdgeInsets.only(
                left: padding.left + 12,
                right: padding.right + 12,
                top: 12,
                bottom: padding.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  logsText,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
    );
  }
}
