import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/ssh_form_provider.dart';
import '../common/fields.dart';
import '../common/form_card.dart';

class SshScreen extends ConsumerWidget {
  const SshScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sshFormProvider);
    final notifier = ref.read(sshFormProvider.notifier);

    return FormCard(
      title: 'SFTP / SSH CONNECTION',
      actionLabel: 'CONNECT',
      onAction: notifier.connect,
      children: [
        HostPortField(
          hostLabel: 'HOST / IP ADDRESS',
          hostController: notifier.host,
          hostHint: '192.168.1.100 or ssh.domain.com',
          portController: notifier.port,
          portHint: '22',
          onChanged: (_) => notifier.touch(),
        ),
        AcTextField(
          label: 'USERNAME',
          controller: notifier.user,
          hint: 'root / admin',
          onChanged: (_) => notifier.touch(),
        ),
        PasswordField(
          label: 'PASSWORD / PASSPHRASE',
          controller: notifier.pass,
          hint: 'Password or key passphrase',
          obscure: state.obscure,
          onToggle: () => notifier.setObscure(!state.obscure),
          onChanged: (_) => notifier.touch(),
        ),
        PathField(
          label: 'PRIVATE KEY FILE (OPTIONAL)',
          controller: notifier.key,
          hint: 'Path to id_rsa / id_ed25519',
          buttonLabel: 'BROWSE',
          onPick: notifier.browseKey,
          onChanged: (_) => notifier.touch(),
        ),
      ],
    );
  }
}
