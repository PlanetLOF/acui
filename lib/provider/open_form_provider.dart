// OPEN-LOCAL-VAULT form: path + password, plus the OPEN VAULT action that
// hands off to the session notifier. AutoDisposed like the other forms.

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter/material.dart' show TextEditingController;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_provider.dart';
import 'session_provider.dart';

class OpenFormState {
  const OpenFormState({
    this.obscure = true,
    this.busy = false,
    this.revision = 0,
    this.notice,
  });

  final bool obscure;
  final bool busy;

  /// Bumped on every text change so the UI rebuilds around the controllers.
  final int revision;

  /// Transient error message surfaced as a snackbar by the screen.
  final String? notice;

  OpenFormState copyWith({
    bool? obscure,
    bool? busy,
    int? revision,
    String? notice,
  }) => OpenFormState(
    obscure: obscure ?? this.obscure,
    busy: busy ?? this.busy,
    revision: revision ?? this.revision,
    notice: notice ?? this.notice,
  );
}

class OpenFormNotifier extends Notifier<OpenFormState> {
  final path = TextEditingController();
  final pass = TextEditingController();

  @override
  OpenFormState build() {
    ref.onDispose(() {
      path.dispose();
      pass.dispose();
    });
    return const OpenFormState();
  }

  bool get canOpen => path.text.isNotEmpty && pass.text.isNotEmpty;

  void touch() =>
      state = state.copyWith(revision: state.revision + 1, notice: null);
  void setObscure(bool v) => state = state.copyWith(obscure: v);

  Future<void> browse() async {
    if (state.busy) return;
    final p = await ref.read(fileServiceProvider).pickVault();
    if (p != null) {
      path.text = p;
      touch();
    }
  }

  Future<void> open() async {
    if (state.busy || !canOpen) return;
    final p = path.text.trim();
    final pw = pass.text;
    state = state.copyWith(busy: true, notice: null);
    try {
      await ref.read(vaultSessionProvider.notifier).open(p, pw);
      // Success: the shell switches to the browser and this form (and its
      // password controller) is disposed by autoDispose — do not touch state.
    } on AutocipherException catch (e) {
      state = state.copyWith(busy: false, notice: e.message);
    } catch (e) {
      state = state.copyWith(busy: false, notice: '$e');
    }
  }
}

final openFormProvider =
    NotifierProvider.autoDispose<OpenFormNotifier, OpenFormState>(
      OpenFormNotifier.new,
    );
