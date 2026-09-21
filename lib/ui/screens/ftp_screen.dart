import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/ftp_form_provider.dart';
import '../common/fields.dart';
import '../common/form_card.dart';

class FtpScreen extends ConsumerWidget {
  const FtpScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ftpFormProvider);
    final notifier = ref.read(ftpFormProvider.notifier);
    final cs = Theme.of(context).colorScheme;

    return FormCard(
      title: 'FTP / FTPS SERVER',
      actionLabel: 'CONNECT',
      onAction: notifier.connect,
      children: [
        HostPortField(
          hostLabel: 'HOST / SERVER',
          hostController: notifier.host,
          hostHint: 'ftp.example.com',
          portController: notifier.port,
          portHint: '21',
          onChanged: (_) => notifier.touch(),
        ),
        AcDropdown<TlsMode>(
          label: 'ENCRYPTION (TLS)',
          value: state.tls,
          options: {for (final m in TlsMode.values) m: m.label},
          onChanged: notifier.setTls,
        ),
        if (state.tls != TlsMode.none)
          CheckboxListTile(
            value: state.allowUnsigned,
            onChanged: (v) => notifier.setAllowUnsigned(v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              'ALLOW UNSIGNED SSL CERTIFICATES',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 0.5,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        AcTextField(
          label: 'USERNAME',
          controller: notifier.user,
          hint: 'anonymous / user',
          onChanged: (_) => notifier.touch(),
        ),
        PasswordField(
          label: 'PASSWORD',
          controller: notifier.pass,
          hint: 'Enter FTP password',
          obscure: state.obscure,
          onToggle: () => notifier.setObscure(!state.obscure),
          onChanged: (_) => notifier.touch(),
        ),
      ],
    );
  }
}
