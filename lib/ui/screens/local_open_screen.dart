import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/open_form_provider.dart';
import '../common/fields.dart';
import '../common/form_card.dart';
import '../format.dart';

/// Open a vault from the local provider.
///
/// The Argon2id unlock runs on a worker isolate inside `VaultSession.open`;
/// success switches the app scene to the vault browser, which owns the
/// session until the user locks it.
///
/// The form state lives in [openFormProvider]; this widget is a pure consumer
/// that renders it and surfaces transient failures as snackbars.
class LocalOpenScreen extends ConsumerWidget {
  const LocalOpenScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(openFormProvider);
    final notifier = ref.read(openFormProvider.notifier);

    // Surface transient failures (wrong password etc.) as snackbars.
    ref.listen<String?>(openFormProvider.select((s) => s.notice), (_, notice) {
      if (notice != null) showSnack(context, notice);
    });

    return FormCard(
      title: 'OPEN LOCAL VAULT (.AC)',
      actionLabel: 'OPEN VAULT',
      onAction: state.busy || !notifier.canOpen ? null : notifier.open,
      busy: state.busy,
      children: [
        PathField(
          label: 'VAULT FILE (.ac)',
          controller: notifier.path,
          hint: '/path/to/vault.ac',
          buttonLabel: 'BROWSE',
          onPick: notifier.browse,
          onChanged: (_) => notifier.touch(),
        ),
        PasswordField(
          label: 'PASSWORD',
          controller: notifier.pass,
          hint: 'Enter vault password',
          obscure: state.obscure,
          onToggle: () => notifier.setObscure(!state.obscure),
          onChanged: (_) => notifier.touch(),
        ),
      ],
    );
  }
}
