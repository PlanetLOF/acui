import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Replaces the Dioxus `Router` enum: which connection screen is showing.
enum ProviderTab {
  ftp('FTP/FTPS'),
  ssh('SFTP/SSH'),
  cloud('CLOUD'),
  create('CREATE'),
  open('OPEN');

  const ProviderTab(this.label);
  final String label;
}

class ProviderTabNotifier extends Notifier<ProviderTab> {
  @override
  ProviderTab build() => ProviderTab.ftp;

  void select(ProviderTab tab) => state = tab;
}

final providerTabProvider = NotifierProvider<ProviderTabNotifier, ProviderTab>(
  ProviderTabNotifier.new,
);
