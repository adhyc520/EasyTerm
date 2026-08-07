import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';

enum RemoteState {
  loading,
  empty,
  notInstalled,
  denied,
  disconnected,
  error,
  data,
}

/// 远程数据应用的统一 loading / empty / error / retry 状态视图。
class RemoteStateView extends StatelessWidget {
  const RemoteStateView({
    super.key,
    required this.state,
    this.message,
    this.detail,
    this.onRetry,
    this.retryLabel,
    required this.data,
  });

  final RemoteState state;
  final String? message;
  final String? detail;
  final VoidCallback? onRetry;
  final String? retryLabel;
  final Widget data;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      RemoteState.loading => const _Loading(),
      RemoteState.empty => _Placeholder(
          icon: Icons.inbox_outlined,
          text: message ?? '暂无数据',
          detail: detail,
          onRetry: onRetry,
          retryLabel: retryLabel,
        ),
      RemoteState.notInstalled => _Placeholder(
          icon: Icons.download_outlined,
          text: message ?? '未安装',
          detail: detail,
          onRetry: onRetry,
          retryLabel: retryLabel ?? '复制安装命令',
        ),
      RemoteState.denied => _Placeholder(
          icon: Icons.lock_outline,
          text: message ?? '权限不足',
          detail: detail,
          onRetry: onRetry,
          retryLabel: retryLabel ?? '以 sudo 重试',
        ),
      RemoteState.disconnected => _Placeholder(
          icon: Icons.cloud_off,
          text: message ?? '未连接',
          detail: detail,
          onRetry: onRetry,
          retryLabel: retryLabel ?? '重连',
        ),
      RemoteState.error => _Placeholder(
          icon: Icons.error_outline,
          text: message ?? '加载失败',
          detail: detail,
          onRetry: onRetry,
          retryLabel: retryLabel ?? '重试',
        ),
      RemoteState.data => data,
    };
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.text,
    this.detail,
    this.onRetry,
    this.retryLabel,
  });

  final IconData icon;
  final String text;
  final String? detail;
  final VoidCallback? onRetry;
  final String? retryLabel;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: wb.textMuted),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: wb.primaryText,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: wb.textMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: onRetry,
                child: Text(retryLabel ?? '重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
