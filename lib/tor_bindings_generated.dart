// ignore_for_file: always_specify_types
// ignore_for_file: camel_case_types
// ignore_for_file: non_constant_identifier_names

// AUTO GENERATED FILE, DO NOT EDIT.
//
// Generated by `package:ffigen`.
import 'dart:ffi' as ffi;

/// Bindings for `native/tor-ffi/target/tor-ffi.hpp`.
///
/// Regenerate bindings with `flutter pub run ffigen --config ffigen.yaml`.
///
class TorBindings {
  /// Holds the symbol lookup function.
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
      _lookup;

  /// The symbols are looked up in [dynamicLibrary].
  TorBindings(ffi.DynamicLibrary dynamicLibrary)
      : _lookup = dynamicLibrary.lookup;

  /// The symbols are looked up with [lookup].
  TorBindings.fromLookup(
      ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
          lookup)
      : _lookup = lookup;

  void tor_hello() {
    return _tor_hello();
  }

  late final _tor_helloPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function()>>('tor_hello');
  late final _tor_hello = _tor_helloPtr.asFunction<void Function()>();

  bool tor_start(
    ffi.Pointer<ffi.Char> conf_path,
  ) {
    return _tor_start(
      conf_path,
    );
  }

  late final _tor_startPtr =
      _lookup<ffi.NativeFunction<ffi.Bool Function(ffi.Pointer<ffi.Char>)>>(
          'tor_start');
  late final _tor_start =
      _tor_startPtr.asFunction<bool Function(ffi.Pointer<ffi.Char>)>();
}
