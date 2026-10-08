// apps/desktop/lib/ui/settings_page.dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../services/network.dart';
import 'format.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.services});

  final AppServices services;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.services.settings.deviceName);
  late final TextEditingController _library =
      TextEditingController(text: widget.services.settings.libraryPath);
  late final TextEditingController _ffmpeg =
      TextEditingController(text: widget.services.settings.ffmpegPath ?? '');

  @override
  void dispose() {
    _name.dispose();
    _library.dispose();
    _ffmpeg.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, s.ffmpeg]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _section(theme, '电脑名称（手机上显示）'),
            Row(children: [
              Expanded(child: TextField(controller: _name)),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () async {
                  final v = _name.text.trim();
                  if (v.isEmpty) return;
                  await s.settings.update((x) => x.deviceName = v);
                  await s.startNetworking();
                  _toast('已保存');
                },
                child: const Text('保存'),
              ),
            ]),
            const SizedBox(height: 28),
            _section(theme, '媒体库文件夹'),
            Row(children: [
              Expanded(child: TextField(controller: _library)),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () async {
                  final v = _library.text.trim();
                  if (v.isEmpty) return;
                  try {
                    await Directory(v).create(recursive: true);
                    await s.changeLibrary(v);
                    _toast('媒体库已切换');
                  } catch (e) {
                    _toast('无法使用这个文件夹：$e');
                  }
                },
                child: const Text('切换'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => revealInExplorer(s.library.rootPath),
                child: const Text('打开'),
              ),
            ]),
            const SizedBox(height: 4),
            Text('收到的原片按「年/月」存放，转换结果在 _converted 子文件夹。', style: theme.textTheme.bodySmall),
            const SizedBox(height: 28),
            _section(theme, 'ffmpeg（HEIC 显示、缩略图、转换需要）'),
            Text(
              s.ffmpeg.available ? '✓ ${s.ffmpeg.version ?? s.ffmpeg.ffmpeg}\n${s.ffmpeg.ffmpeg}' : '✗ 未找到 ffmpeg',
              style: TextStyle(color: s.ffmpeg.available ? null : theme.colorScheme.error),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _ffmpeg,
                  decoration: const InputDecoration(hintText: r'例如 C:\ffmpeg\bin\ffmpeg.exe（留空自动查找）'),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () async {
                  final v = _ffmpeg.text.trim();
                  await s.settings.update((x) => x.ffmpegPath = v.isEmpty ? null : v);
                  await s.ffmpeg.locate();
                  _toast(s.ffmpeg.available ? '已找到 ffmpeg' : '这个路径下没有可用的 ffmpeg');
                },
                child: const Text('检测'),
              ),
            ]),
            const SizedBox(height: 4),
            Text('自动查找顺序：上面填的路径 → 程序目录下的 ffmpeg\\ffmpeg.exe → 系统 PATH。需要 ffmpeg 7.1 或更新版本才能正确解码 iPhone 的 HEIC。',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 28),
            _section(theme, '网络'),
            Text('接收端口：${s.server.port}'),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () async => _toast(await addFirewallRules(s.server.port) ? '防火墙规则已添加' : '没有添加'),
                icon: const Icon(Icons.shield_outlined),
                label: const Text('允许 LocalRoll 通过 Windows 防火墙'),
              ),
            ),
            const SizedBox(height: 28),
            _section(theme, '已配对的手机'),
            if (s.settings.trusted.isEmpty) const Text('还没有配对的手机'),
            for (final d in s.settings.trusted.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(d.platform == 'ios' ? Icons.phone_iphone : Icons.phone_android),
                title: Text(d.name),
                subtitle: Text('配对于 ${formatDate(DateTime.fromMillisecondsSinceEpoch(d.pairedMs))}'),
                trailing: TextButton(
                  onPressed: () async {
                    await s.settings.update((x) => x.trusted.remove(d.id));
                    _toast('已取消配对：${d.name}');
                  },
                  child: const Text('取消配对'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: theme.textTheme.titleMedium),
      );
}
