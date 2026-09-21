import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../provider/provider_tab_provider.dart';
import '../../provider/session_provider.dart';
import '../common/section_header.dart';
import '../vault_browser_screen.dart';
import 'ftp_screen.dart';
import 'local_create_screen.dart';
import 'local_open_screen.dart';
import 'ssh_screen.dart';

/// App shell: shows the provider switcher + active form, or the vault browser
/// while a session is open (scene switch driven by [vaultSessionProvider]).
class ProviderScreen extends ConsumerWidget {
  const ProviderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(vaultSessionProvider);
    if (session != null) {
      return const VaultBrowserScreen();
    }
    return const _ProviderShell();
  }
}

class _ProviderShell extends ConsumerWidget {
  const _ProviderShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(providerTabProvider);

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 16,
                  children: [
                    SvgPicture.asset('assets/pic_svg/acui.svg', height: 96),
                    const SectionHeader('PROVIDER'),
                    SegmentedButton<ProviderTab>(
                      showSelectedIcon: false,
                      segments: [
                        for (final t in ProviderTab.values)
                          ButtonSegment(value: t, label: Text(t.label)),
                      ],
                      selected: {tab},
                      onSelectionChanged: (s) => ref
                          .read(providerTabProvider.notifier)
                          .select(s.first),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: KeyedSubtree(
                        key: ValueKey(tab),
                        child: switch (tab) {
                          ProviderTab.ftp => const FtpScreen(),
                          ProviderTab.ssh => const SshScreen(),
                          ProviderTab.create => const LocalCreateScreen(),
                          ProviderTab.open => const LocalOpenScreen(),
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
