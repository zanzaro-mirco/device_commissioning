import 'package:commissioning_protocol/commissioning_protocol.dart';

/// I decimi di grado del protocollo diventano gradi solo qui, per chi legge.
String formatTemperature(int tenths) {
  final sign = tenths < 0 ? '-' : '';
  final value = tenths.abs();
  return '$sign${value ~/ 10},${value % 10} °C';
}

String formatUptime(int seconds) {
  if (seconds < 60) return '$seconds s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  if (hours < 24) return '$hours h ${minutes % 60} min';
  return '${hours ~/ 24} g ${hours % 24} h';
}

String modeLabel(Mode mode) => switch (mode) {
  Mode.off => 'Spenta',
  Mode.comfort => 'Comfort',
  Mode.eco => 'Economia',
};

String describeParams(Params params) =>
    '${formatTemperature(params.setpoint)}, ${modeLabel(params.mode).toLowerCase()}';
