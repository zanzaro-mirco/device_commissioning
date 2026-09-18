import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'link/device_link.dart';
import 'scan/scan_cubit.dart';
import 'scan/scan_page.dart';

/// L'app riceve il [DeviceLink] da fuori: nel `main` è il Bluetooth vero, nei
/// test la centralina finta.
class CommissioningApp extends StatelessWidget {
  const CommissioningApp({super.key, required this.link});

  final DeviceLink link;

  @override
  Widget build(BuildContext context) {
    return RepositoryProvider.value(
      value: link,
      child: BlocProvider(
        create: (_) => ScanCubit(link),
        child: MaterialApp(
          title: 'Messa in servizio',
          theme: ThemeData(colorSchemeSeed: Colors.teal),
          darkTheme: ThemeData(
            colorSchemeSeed: Colors.teal,
            brightness: Brightness.dark,
          ),
          home: const ScanPage(),
        ),
      ),
    );
  }
}
