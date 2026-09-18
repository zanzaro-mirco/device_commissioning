import 'package:flutter/material.dart';

import 'app.dart';
import 'link/device_link.dart';

void main() => runApp(CommissioningApp(link: BleDeviceLink()));
