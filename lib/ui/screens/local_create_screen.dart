import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/create_form_provider.dart';
import '../common/fields.dart';
import '../common/form_card.dart';
import '../common/section_header.dart';
import '../format.dart';

/// Create a vault at the local provider.
///
/// KDF dropdown values map 1:1 onto the engine: memory ∈ {128, 256, 512} MiB
/// and t/p ∈ 1..4 (Argon2 rejects only t = 0). BROWSE picks a target folder
/// and fills in `vault.ac`; the vault is only written when CREATE VAULT runs.
///
/// The form state lives in [createFormProvider]; this widget is a pure
/// consumer that renders it and surfaces transient failures as snackbars.
class LocalCreateScreen extends ConsumerWidget {
  const LocalCreateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(createFormProvider);
    final notifier = ref.read(createFormProvider.notifier);

    // Surface transient failures (wrong password etc.) as snackbars.
    ref.listen<String?>(createFormProvider.select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice != null) showSnack(context, notice);
    });

    return FormCard(
      title: 'CREATE NEW LOCAL VAULT (.AC)',
      actionLabel: 'CREATE VAULT',
      onAction: state.busy || !notifier.canCreate ? null : notifier.create,
      busy: state.busy,
      children: [
        PathField(
          label: 'VAULT FILE (.ac)',
          controller: notifier.path,
          hint: '/path/to/new_vault.ac',
          buttonLabel: 'BROWSE',
          onPick: notifier.browse,
          onChanged: (_) => notifier.touch(),
        ),
        PasswordField(
          label: 'PASSWORD',
          controller: notifier.pass,
          hint: 'Enter new vault password',
          obscure: state.obscure,
          onToggle: () => notifier.setObscure(!state.obscure),
          onGenerate: notifier.generate,
          onChanged: (_) => notifier.touch(),
        ),
        PasswordField(
          label: 'CONFIRM PASSWORD',
          controller: notifier.confirm,
          hint: 'Confirm new vault password',
          obscure: state.obscure,
          onToggle: () => notifier.setObscure(!state.obscure),
          onChanged: (_) => notifier.touch(),
          errorText: notifier.mismatch,
        ),
        const Divider(),
        const SectionHeader('KEY DERIVATION PARAMETERS', small: true),
        AcDropdown<int>(
          label: 'MEMORY COST',
          value: state.memory,
          options: const {128: '128 MiB', 256: '256 MiB', 512: '512 MiB'},
          onChanged: notifier.setMemory,
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Expanded(
              child: AcDropdown<int>(
                label: 'ITERATIONS',
                value: state.iterations,
                options: {
                  for (final i in [1, 2, 3, 4]) i: '$i',
                },
                onChanged: notifier.setIterations,
              ),
            ),
            Expanded(
              child: AcDropdown<int>(
                label: 'PARALLELISM',
                value: state.parallelism,
                options: {
                  for (final i in [1, 2, 3, 4]) i: '$i',
                },
                onChanged: notifier.setParallelism,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
