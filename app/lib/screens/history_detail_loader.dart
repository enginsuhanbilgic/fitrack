/// Resolves a [SessionDetail] by id, then renders
/// `SummaryScreen.fromSession(detail)`.
///
/// Tiny wrapper screen so `HistoryScreen`'s list-tile tap path can route into
/// SummaryScreen without pre-loading the detail (avoids thrashing the DB for
/// every visible row). Deleted sessions (null detail) show a brief error
/// scaffold with a back button.
library;

import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/db/session_dtos.dart';
import 'summary_screen.dart';

class HistoryDetailLoader extends StatelessWidget {
  const HistoryDetailLoader({super.key, required this.sessionId});

  final int sessionId;

  @override
  Widget build(BuildContext context) {
    final repo = AppServicesScope.of(context).sessionRepository;
    return FutureBuilder<SessionDetail?>(
      future: repo.getSession(sessionId),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return _ErrorScaffold(
            title: "Couldn't load session",
            detail: '${snap.error}',
          );
        }
        final detail = snap.data;
        if (detail == null) {
          return const _ErrorScaffold(
            title: 'Session not found',
            detail: 'It may have been deleted.',
          );
        }
        return SummaryScreen.fromSession(detail);
      },
    );
  }
}

class _ErrorScaffold extends StatelessWidget {
  const _ErrorScaffold({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
