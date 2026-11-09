import 'dart:ffi';
import 'dart:io';

typedef _SetStateC = Uint32 Function(Uint32);
typedef _SetStateDart = int Function(int);

/// Stops Windows from sleeping while a transfer runs (screen may still
/// turn off). Calls nest; the last [release] restores normal behaviour.
class KeepAwake {
  static int _holders = 0;
  static _SetStateDart? _fn;

  static const _continuous = 0x80000000;
  static const _system = 0x00000001;

  static _SetStateDart? get _set {
    if (!Platform.isWindows) return null;
    try {
      return _fn ??= DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_SetStateC, _SetStateDart>('SetThreadExecutionState');
    } catch (_) {
      return null;
    }
  }

  static void acquire() {
    if (_holders++ == 0) _set?.call(_continuous | _system);
  }

  static void release() {
    if (_holders == 0) return;
    if (--_holders == 0) _set?.call(_continuous);
  }

  static Future<T> during<T>(Future<T> Function() work) async {
    acquire();
    try {
      return await work();
    } finally {
      release();
    }
  }
}
