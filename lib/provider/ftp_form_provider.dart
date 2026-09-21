// FTP/FTPS connection form state. The connect action is a stub until the
// engine ships a network client; the form itself is fully Riverpod-driven.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show TextEditingController;
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TlsMode {
  explicit('Explicit TLS (FTPS - Port 21)'),
  implicit('Implicit TLS (FTPS - Port 990)'),
  none('Plain FTP (Insecure)');

  const TlsMode(this.label);
  final String label;
}

class FtpFormState {
  const FtpFormState({
    this.obscure = true,
    this.tls = TlsMode.explicit,
    this.allowUnsigned = false,
    this.revision = 0,
  });

  final bool obscure;
  final TlsMode tls;
  final bool allowUnsigned;

  /// Bumped on every text change so the UI rebuilds around the controllers.
  final int revision;

  FtpFormState copyWith({
    bool? obscure,
    TlsMode? tls,
    bool? allowUnsigned,
    int? revision,
  }) => FtpFormState(
    obscure: obscure ?? this.obscure,
    tls: tls ?? this.tls,
    allowUnsigned: allowUnsigned ?? this.allowUnsigned,
    revision: revision ?? this.revision,
  );
}

class FtpFormNotifier extends Notifier<FtpFormState> {
  final host = TextEditingController();
  final port = TextEditingController(text: '21');
  final user = TextEditingController();
  final pass = TextEditingController();

  @override
  FtpFormState build() {
    ref.onDispose(() {
      for (final c in [host, port, user, pass]) {
        c.dispose();
      }
    });
    return const FtpFormState();
  }

  void touch() => state = state.copyWith(revision: state.revision + 1);
  void setObscure(bool v) => state = state.copyWith(obscure: v);
  void setTls(TlsMode v) => state = state.copyWith(tls: v);
  void setAllowUnsigned(bool v) => state = state.copyWith(allowUnsigned: v);

  void connect() {
    debugPrint(
      'Connecting FTP to ${host.text}:${port.text} as ${user.text}, '
      'unsigned_ssl: ${state.allowUnsigned}',
    );
  }
}

final ftpFormProvider =
    NotifierProvider.autoDispose<FtpFormNotifier, FtpFormState>(
      FtpFormNotifier.new,
    );
