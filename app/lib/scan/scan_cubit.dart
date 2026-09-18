import 'dart:async';

import 'package:ble_bridge/ble_bridge.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../link/device_link.dart';

enum ScanStatus {
  idle,
  scanning,
  permissionDenied,

  /// L'utente ha scelto «non chiedere più»: solo le impostazioni di sistema
  /// possono riaprire la porta, e l'app deve dirlo invece di richiedere.
  permissionPermanentlyDenied,
  bluetoothOff,
  bluetoothUnavailable,
  failed,
}

class ScanState extends Equatable {
  const ScanState({
    this.status = ScanStatus.idle,
    this.devices = const [],
    this.error,
  });

  final ScanStatus status;

  /// Dalla più vicina alla più lontana.
  final List<FoundDevice> devices;
  final String? error;

  ScanState copyWith({
    ScanStatus? status,
    List<FoundDevice>? devices,
    String? error,
  }) {
    return ScanState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      error: error,
    );
  }

  @override
  List<Object?> get props => [status, devices, error];
}

/// Cerca le centraline. La scansione si ferma da sola dopo [duration]: su
/// Android una scansione lasciata aperta consuma batteria, e il sistema
/// limita quante se ne possono avviare in poco tempo.
class ScanCubit extends Cubit<ScanState> {
  ScanCubit(this._link, {this.duration = const Duration(seconds: 15)})
    : super(const ScanState());

  final DeviceLink _link;
  final Duration duration;
  StreamSubscription<FoundDevice>? _subscription;
  Timer? _timer;
  final _found = <String, FoundDevice>{};

  Future<void> start() async {
    await stop();
    final permission = await _link.requestPermissions();
    if (isClosed) return;
    switch (permission) {
      case PermissionState.granted:
        break;
      case PermissionState.denied:
        emit(state.copyWith(status: ScanStatus.permissionDenied));
        return;
      case PermissionState.permanentlyDenied:
        emit(state.copyWith(status: ScanStatus.permissionPermanentlyDenied));
        return;
    }

    final adapter = await _link.adapterState();
    if (isClosed) return;
    switch (adapter) {
      case AdapterState.on:
        break;
      case AdapterState.off:
        emit(state.copyWith(status: ScanStatus.bluetoothOff));
        return;
      case AdapterState.unavailable:
      case AdapterState.unauthorized:
        emit(state.copyWith(status: ScanStatus.bluetoothUnavailable));
        return;
    }

    _found.clear();
    emit(const ScanState(status: ScanStatus.scanning));
    _subscription = _link.scan().listen(
      (device) {
        _found[device.id] = device;
        final devices = _found.values.toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
        emit(state.copyWith(devices: devices));
      },
      onError: (Object error) {
        unawaited(stop());
        emit(state.copyWith(status: ScanStatus.failed, error: '$error'));
      },
    );
    _timer = Timer(duration, () => unawaited(stop()));
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription == null) return;
    await subscription.cancel();
    if (!isClosed && state.status == ScanStatus.scanning) {
      emit(state.copyWith(status: ScanStatus.idle));
    }
  }

  @override
  Future<void> close() async {
    await stop();
    return super.close();
  }
}
