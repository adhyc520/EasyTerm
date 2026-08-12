import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';

/// 预设助手 Prompt 模板（中/英）。
class AssistantPromptTemplates extends StatelessWidget {
  const AssistantPromptTemplates({
    super.key,
    required this.zh,
    required this.onSelect,
    this.enabled = true,
  });

  final bool zh;
  final ValueChanged<String> onSelect;
  final bool enabled;

  static List<({String label, String prompt})> presets({required bool zh}) {
    if (zh) {
      return const [
        (
          label: '性能分析',
          prompt: '请分析当前系统的性能瓶颈：CPU、内存、磁盘 I/O 与负载。给出可能原因和可执行的排查步骤。',
        ),
        (
          label: '安全检查',
          prompt: '请检查这台主机的基本安全配置：开放端口、可疑进程、SSH/防火墙相关风险，并给出优先级建议。',
        ),
        (
          label: '磁盘占用',
          prompt: '请查看磁盘空间占用，找出占用最大的目录/文件，并说明清理建议（不要直接删除）。',
        ),
        (
          label: '最近错误',
          prompt: '请分析最近的系统/服务错误日志，总结关键报错并给出排查方向。',
        ),
      ];
    }
    return const [
      (
        label: 'Performance',
        prompt:
            'Analyze performance bottlenecks on this host: CPU, memory, disk I/O, and load. Suggest likely causes and concrete next checks.',
      ),
      (
        label: 'Security',
        prompt:
            'Review basic security posture: listening ports, suspicious processes, SSH/firewall risks. Prioritize findings.',
      ),
      (
        label: 'Disk usage',
        prompt:
            'Inspect disk usage and find the largest directories/files. Suggest cleanup options without deleting anything.',
      ),
      (
        label: 'Recent errors',
        prompt:
            'Analyze recent system/service error logs, summarize key failures, and propose investigation steps.',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final items = presets(zh: zh);
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final item = items[i];
          return ActionChip(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            label: Text(
              item.label,
              style: TextStyle(
                fontSize: 11.5,
                color: enabled ? wb.primaryText : wb.textMuted,
              ),
            ),
            backgroundColor: wb.panelElevated,
            side: BorderSide(color: wb.border),
            onPressed: enabled ? () => onSelect(item.prompt) : null,
          );
        },
      ),
    );
  }
}
