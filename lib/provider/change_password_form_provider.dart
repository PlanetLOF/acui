// Change-password dialog form: new password + confirm + KDF preset. The
// sheet calls `reset()` before showing the dialog, and the dialog pops once
// `done` flips to true.

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter/material.dart' show TextEditingController;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session_provider.dart';

class ChangePasswordFormState {
  const ChangePasswordFormState({
    this.obscure = true,
    this.busy = false,
    this.done = false,
    this.revision = 0,
    this.notice,
  });

  final bool obscure;
  final bool busy;

  /// Set to true once the vault has been re-keyed (pops the dialog).
  final bool done;

  /// Bumped on every text change so the UI rebuilds around the controllers.
  final int revision;

  /// Transient error message surfaced as a snackbar by the dialog.
  final String? notice;

  ChangePasswordFormState copyWith({
    bool? obscure,
    bool? busy,
    bool? done,
    int? revision,
    String? notice,
  }) => ChangePasswordFormState(
    obscure: obscure ?? this.obscure,
    busy: busy ?? this.busy,
    done: done ?? this.done,
    revision: revision ?? this.revision,
    notice: notice ?? this.notice,
  );
}

class ChangePasswordFormNotifier extends Notifier<ChangePasswordFormState> {
  final password = TextEditingController();
  final confirm = TextEditingController();
  KdfPreset preset = KdfPreset.kdf256;

  @override
  ChangePasswordFormState build() {
    ref.onDispose(() {
      password.dispose();
      confirm.dispose();
    });
    return const ChangePasswordFormState();
  }

  /// Clear the form before opening the dialog.
  void reset() {
    password.clear();
    confirm.clear();
    preset = KdfPreset.kdf256;
    state = const ChangePasswordFormState();
  }

  void touch() =>
      state = state.copyWith(revision: state.revision + 1, notice: null);
  void setObscure(bool v) => state = state.copyWith(obscure: v);
  void setPreset(KdfPreset p) {
    preset = p;
    touch();
  }

  Future<void> submit() async {
    if (state.busy) return;
    if (password.text.isEmpty || password.text != confirm.text) {
      state = state.copyWith(notice: 'Passwords must match and be non-empty.');
      return;
    }
    state = state.copyWith(busy: true, notice: null);
    final session = ref.read(vaultSessionProvider);
    if (session == null) {
      state = state.copyWith(busy: false, notice: 'No open vault.');
      return;
    }
    try {
      await session.changePassword(password.text, preset);
      state = state.copyWith(busy: false, done: true);
    } on AutocipherException catch (e) {
      state = state.copyWith(busy: false, notice: e.message);
    }
  }
}

final changePasswordFormProvider =
    NotifierProvider.autoDispose<
      ChangePasswordFormNotifier,
      ChangePasswordFormState
    >(ChangePasswordFormNotifier.new);
