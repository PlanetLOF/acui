// SFTP/SSH connection form state. The connect action is a stub until the
// engine ships a network client; the form itself is fully Riverpod-driven.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show TextEditingController;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_provider.dart';

class SshFormState {
  const SshFormState({this.obscure = true, this.revision = 0});

  final bool obscure;

  /// Bumped on every text change so the UI rebuilds around the controllers.
  final int revision;

  SshFormState copyWith({bool? obscure, int? revision}) => SshFormState(
    obscure: obscure ?? this.obscure,
    revision: revision ?? this.revision,
  );
}

class SshFormNotifier extends Notifier<SshFormState> {
  final host = TextEditingController();
  final port = TextEditingController(text: '22');
  final user = TextEditingController(text: 'root');
  final pass = TextEditingController();
  final key = TextEditingController();

  @override
  SshFormState build() {
    ref.onDispose(() {
      for (final c in [host, port, user, pass, key]) {
        c.dispose();
      }
    });
    return const SshFormState();
  }

  void touch() => state = state.copyWith(revision: state.revision + 1);
  void setObscure(bool v) => state = state.copyWith(obscure: v);

  Future<void> browseKey() async {
    final path = await ref.read(fileServiceProvider).pickPrivateKey();
    if (path != null) {
      key.text = path;
      touch();
    }
  }

  void connect() {
    debugPrint('Connecting SFTP/SSH to ${user.text}@${host.text}:${port.text}');
  }
}

final sshFormProvider =
    NotifierProvider.autoDispose<SshFormNotifier, SshFormState>(
      SshFormNotifier.new,
    );
