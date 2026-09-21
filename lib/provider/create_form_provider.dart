// CREATE-NEW-VAULT form: path, password, confirm, and the KDF parameters,
// plus the CREATE VAULT action that hands off to the session notifier.
//
// The form provider is autoDisposed, so switching tabs (or locking a vault
// and returning) starts a fresh form — passwords never linger.

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter/material.dart' show TextEditingController;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_provider.dart';
import 'password_provider.dart';
import 'session_provider.dart';

class CreateFormState {
  const CreateFormState({
    this.obscure = true,
    this.busy = false,
    this.memory = 256,
    this.iterations = 4,
    this.parallelism = 4,
    this.revision = 0,
    this.notice,
  });

  final bool obscure;
  final bool busy;

  /// Argon2id memory cost in MiB — one of 128, 256, 512.
  final int memory;
  final int iterations; // Argon2 t
  final int parallelism; // Argon2 p

  /// Bumped on every text change so the UI rebuilds around the controllers.
  final int revision;

  /// Transient error message surfaced as a snackbar by the screen.
  final String? notice;

  CreateFormState copyWith({
    bool? obscure,
    bool? busy,
    int? memory,
    int? iterations,
    int? parallelism,
    int? revision,
    String? notice,
  }) => CreateFormState(
    obscure: obscure ?? this.obscure,
    busy: busy ?? this.busy,
    memory: memory ?? this.memory,
    iterations: iterations ?? this.iterations,
    parallelism: parallelism ?? this.parallelism,
    revision: revision ?? this.revision,
    notice: notice ?? this.notice,
  );
}

class CreateFormNotifier extends Notifier<CreateFormState> {
  final path = TextEditingController();
  final pass = TextEditingController();
  final confirm = TextEditingController();

  @override
  CreateFormState build() {
    ref.onDispose(() {
      for (final c in [path, pass, confirm]) {
        c.dispose();
      }
    });
    return const CreateFormState();
  }

  bool get canCreate =>
      path.text.isNotEmpty && pass.text.isNotEmpty && pass.text == confirm.text;

  String? get mismatch => confirm.text.isNotEmpty && confirm.text != pass.text
      ? 'Passwords do not match'
      : null;

  void touch() =>
      state = state.copyWith(revision: state.revision + 1, notice: null);
  void setObscure(bool v) => state = state.copyWith(obscure: v);
  void setMemory(int v) => state = state.copyWith(memory: v);
  void setIterations(int v) => state = state.copyWith(iterations: v);
  void setParallelism(int v) => state = state.copyWith(parallelism: v);

  Future<void> browse() async {
    if (state.busy) return;
    final p = await ref.read(fileServiceProvider).saveVault();
    if (p != null) {
      path.text = p;
      touch();
    }
  }

  void generate() {
    final pw = ref.read(passwordGeneratorProvider).generate();
    pass.text = pw;
    confirm.text = pw;
    touch();
  }

  Future<void> create() async {
    if (state.busy || !canCreate) return;
    state = state.copyWith(busy: true, notice: null);
    try {
      await ref
          .read(vaultSessionProvider.notifier)
          .create(
            path.text.trim(),
            pass.text,
            KdfPreset(state.memory, state.iterations, state.parallelism),
          );
      // Success: the shell switches to the browser and this form (and its
      // password controllers) is disposed by autoDispose — do not touch state.
    } on AutocipherException catch (e) {
      state = state.copyWith(busy: false, notice: e.message);
    } catch (e) {
      state = state.copyWith(busy: false, notice: '$e');
    }
  }
}

final createFormProvider =
    NotifierProvider.autoDispose<CreateFormNotifier, CreateFormState>(
      CreateFormNotifier.new,
    );
