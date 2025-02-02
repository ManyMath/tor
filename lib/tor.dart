// SPDX-FileCopyrightText: 2022 Foundation Devices Inc.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'models/tor_config.dart';

typedef TorStartRust = Bool Function(Pointer<Utf8>);
typedef TorStartDart = bool Function(Pointer<Utf8>);

typedef TorHelloRust = Void Function();
typedef TorHelloDart = void Function();

DynamicLibrary load(name) {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('lib$name.so');
  } else if (Platform.isLinux) {
    return DynamicLibrary.open('lib$name.so');
  } else if (Platform.isIOS || Platform.isMacOS) {
    // iOS and MacOS are statically linked, so it is the same as the current process
    return DynamicLibrary.process();
  } else if (Platform.isWindows) {
    return DynamicLibrary.open('$name.dll');
  } else {
    throw NotSupportedPlatform('${Platform.operatingSystem} is not supported!');
  }
}

class NotSupportedPlatform implements Exception {
  NotSupportedPlatform(String s);
}

class Tor {
  static late String _libName = "tor_ffi";
  static late DynamicLibrary _lib;

  bool enabled = true;
  bool started = false;
  bool circuitEstablished = false;

  // Periodically check if circuit has been established
  Timer? _connectionChecker;
  bool _shutdownInProgress = false;

  // This stream broadcast just the port for now (-1 if circuit not established)
  final StreamController events = StreamController.broadcast();

  int port = -1;
  int _controlPort = -1;

  String _password = "secret";

  static final Tor _instance = Tor._internal();

  factory Tor() {
    return _instance;
  }

  static Future<Tor> init() async {
    var singleton = Tor._instance;
    return singleton;
  }

  Tor._internal() {
    _lib = load(_libName);
    print("Instance of Tor created!");
  }

  Future<void> start({required Directory torDir}) async {
    // TODO need to refactor configuration file creation out of start() method
    if (_connectionChecker != null) {
      throw Exception("Tor connection has already been started");
    }

    enabled = true;
    events.add(port);

    final rustFunction = _lib.lookup<NativeFunction<TorStartRust>>('tor_start');
    final dartFunction = rustFunction.asFunction<TorStartDart>();

    final _port = await getRandomUnusedPort();
    final _controlPort = await getRandomUnusedPort();
    final password = generatePassword();

    final torConfig = TorConfig(
      dataDirectory: torDir.path,
      logFile: "tor_logs.txt",
      socksPort: _port,
      controlPort: _controlPort,
      password: password,
    );

    new Directory(torConfig.dataDirectory).create().then((Directory directory) {
      new File(torConfig.logFile).create().then((file) {
        file.writeAsStringSync(torConfig.toString());
        if (dartFunction(file.path.toNativeUtf8())) {
          started = true;

          port = torConfig!.socksPort;
          // _controlPort = torConfig!.controlPort;
          // _password = torConfig!.password;

          _connectionChecker = Timer.periodic(Duration(seconds: 5), (timer) {
            _checkIsCircuitEstablished();
          });
        }
      });
    });

    // TODO handle/catch errors and return torConfig
  }

  static String generatePasswordHash(String password) {
    //https://tor.stackexchange.com/a/22591
    var random = Random.secure();

    // Obtain 8 random bytes from the system as salt
    var salt = List<int>.generate(8, (i) => random.nextInt(256));

    // Append the bytes of the user specified password to the salt
    var salted = salt + password.codeUnits;

    // Repeat this sequence until the length is 65536 (0x10000) bytes
    List<int> longSalted = [];
    while (longSalted.length < 65536) {
      longSalted.addAll(salted);
    }

    // If repeating the sequence doesn't exactly end up at this number, cut off any excess bytes
    // Hash the sequence using SHA1
    var digest = sha1.convert(longSalted.sublist(0, 65536));

    // Your hashed control password will be "16:" + Hex(Salt) + "60" + Hex(Sha1)
    // where + is string concatenation and Hex() is "convert bytes to uppercase hexadecimal"
    var hashed = '16:' +
        hex.encode(salt).toUpperCase() +
        '60' +
        hex.encode(digest.bytes).toUpperCase();
    return hashed;
  }

  Future<void> disable() async {
    enabled = false;
    started = false;

    port = -1;
    await _shutdown();
  }

  Future<void> _shutdown() async {
    if (!_shutdownInProgress) {
      _shutdownInProgress = true;
      print("Tor: shutting down! Control port is " + _controlPort.toString());
      events.add(port);

      if (_connectionChecker != null) _connectionChecker!.cancel();

      // This will broadcast we are not using Tor anymore
      if (_controlPort > 0) {
        Socket? socket = await _connectToControl(_controlPort);

        if (socket == null) {
          _shutdownInProgress = false;
          return;
        } else {
          _controlPort = -1;
        }

        // Wait for auth
        await Future.delayed(Duration(seconds: 1));

        // Shut down
        socket.add(utf8.encode('SIGNAL SHUTDOWN\r\n'));
        socket.close();

        circuitEstablished = false;

        // Give Tor a second to shut down
        await Future.delayed(Duration(seconds: 1));
        _shutdownInProgress = false;
        return;
      }
      _shutdownInProgress = false;
    }
  }

  _checkIsCircuitEstablished() async {
    if (_controlPort > 0 && enabled && started) {
      print("Tor: connecting to control port " + _controlPort.toString());
      Socket? socket = await _connectToControl(_controlPort);

      if (socket == null) {
        return;
      }

      socket.listen((List<int> event) {
        String response = utf8.decode(event);
        if (response.contains("250-status/circuit-established=1")) {
          circuitEstablished = true;
          events.add(port);
          _connectionChecker!.cancel();
        }
      });

      socket.add(utf8.encode('getinfo status/circuit-established\r\n'));

      // Wait
      await Future.delayed(Duration(seconds: 2));

      socket.close();
    }
  }

  Future<Socket?> _connectToControl(int port) async {
    // https://iphelix.medium.com/hacking-the-tor-control-protocol-fb844db6a606

    var socket;
    try {
      print('Tor: trying to connect to control port ' + port.toString());
      socket = await Socket.connect('127.0.0.1', port);
    } on Exception catch (_) {
      print("Tor: couldn't connect to control port!");
      return null;
    }

    print('Tor: connected to control port!');

    // TODO: check if we have actually authenticated
    // socket.listen((List<int> event) {
    //   print("Tor control: " + utf8.decode(event));
    // });

    // Authenticate
    socket.add(utf8.encode('AUTHENTICATE "' + _password + '"\r\n'));
    return socket;
  }

  hello() {
    final rustFunction = _lib.lookup<NativeFunction<TorHelloRust>>('tor_hello');
    final dartFunction = rustFunction.asFunction<TorHelloDart>();
    dartFunction();
  }

  Future<int> getRandomUnusedPort({List<int> excluded = const []}) async {
    final Random random = Random.secure();
    int? potentialPort;

    while (true) {
      potentialPort = random.nextInt(65535);
      if (!excluded.contains(potentialPort)) {
        ServerSocket? socket;
        try {
          socket = await ServerSocket.bind("0.0.0.0", potentialPort);

          // found unused port and return it
          return potentialPort;
        } catch (_) {
          // do nothing (continue looping)
        } finally {
          // close socket no matter what
          socket?.close();
        }
      }
    }

    return -1;
  }

  // WARNING probably not safe, just for demo purposes
  String generatePassword([int len = 32]) {
    const allowedChars =
        'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';

    var random = Random.secure();
    return String.fromCharCodes(Iterable.generate(len,
        (_) => allowedChars.codeUnitAt(random.nextInt(allowedChars.length))));
  }
}
