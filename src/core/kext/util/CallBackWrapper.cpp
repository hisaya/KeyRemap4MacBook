#include "CallBackWrapper.hpp"
#include "Config.hpp"
#include "keycode.hpp"

namespace org_pqrs_KeyRemap4MacBook {
  void
  Params_KeyboardEventCallBack::log(const char* message) const
  {
    if (! config.debug) return;

    printf("KeyRemap4MacBook KeyboardEventCallback [%s]: eventType %d, flags 0x%x, key %d, kbdType %d\n",
           message, eventType, flags, key, keyboardType);
  }

  void
  Params_KeyboardSpecialEventCallback::log(const char* message) const
  {
    if (! config.debug) return;

    printf("KeyRemap4MacBook KeyboardSpecialEventCallBack [%s]: eventType %d, flags 0x%x, key %d, flavor %d, guid %lld\n",
           message, eventType, flags, key, flavor, guid);
  }

  void
  Params_RelativePointerEventCallback::log(const char* message) const
  {
    if (! config.debug_pointing) return;

    printf("KeyRemap4MacBook RelativePointerEventCallBack [%s]: buttons: %d, dx: %d, dy: %d\n",
           message, buttons, dx, dy);
  }

  void
  Params_ScrollWheelEventCallback::log(const char* message) const
  {
    if (! config.debug_pointing) return;

#if __x86_64__
    const char* format = "KeyRemap4MacBook ScrollWheelEventCallback [%s]: deltaAxis(%d, %d, %d), fixedDelta(%ld, %ld, %ld), pointDelta(%d,%d,%d), options: %d\n";
#else
    const char* format = "KeyRemap4MacBook ScrollWheelEventCallback [%s]: deltaAxis(%d, %d, %d), fixedDelta(%d, %d, %d), pointDelta(%d,%d,%d), options: %d\n";
#endif
    printf(format,
           message,
           deltaAxis1, deltaAxis2, deltaAxis3,
           fixedDelta1, fixedDelta2, fixedDelta3,
           pointDelta1, pointDelta2, pointDelta3,
           options);
  }

  // ----------------------------------------------------------------------
  void
  Params_KeyboardEventCallBack::apply(KeyboardEventCallback callback) const
  {
    if (! callback) return;

    // ------------------------------------------------------------
    if (key >= KeyCode::VK__BEGIN__) {
      // Invalid keycode
      IOLog("[KeyRemap4MacBook ERROR] Params_KeyboardEventCallBack::apply invalid key:%d\n", key);
      return;
    }

    if (config.option_drop_slowexpose) {
      // Skip if Shift+F8,F9,F10,F11,F12,EXPOSE_ALL.
      if (key == KeyCode::F8 || key == KeyCode::F9 ||
          key == KeyCode::F10 || key == KeyCode::F11 ||
          key == KeyCode::F12 || key == KeyCode::EXPOSE_ALL) {
        if (ModifierFlag::isOn(flags, ModifierFlag::SHIFT_L) ||
            ModifierFlag::isOn(flags, ModifierFlag::SHIFT_R)) {
          return;
        }
      }
    }

    if (config.option_jis_drop_eisuukana_with_modifiers) {
      // Skip if EISUU,KANA with any modifiers.
      if (key == KeyCode::JIS_EISUU || key == KeyCode::JIS_KANA) {
        if (flags != 0) {
          return;
        }
      }
    }

    // ------------------------------------------------------------
    log("sending");
    callback(target, eventType, flags, key, charCode, charSet, origCharCode, origCharSet,
             keyboardType, repeat, ts, sender, refcon);
  }

  void
  Params_KeyboardSpecialEventCallback::apply(KeyboardSpecialEventCallback callback) const
  {
    if (! callback) return;

    log("sending");
    callback(target, eventType, flags, key, flavor, guid, repeat, ts, sender, refcon);
  }

  void
  Params_RelativePointerEventCallback::apply(RelativePointerEventCallback callback) const
  {
    if (! callback) return;

    log("sending");
    callback(target, buttons, dx, dy, ts, sender, refcon);
  }

  void
  Params_ScrollWheelEventCallback::apply(ScrollWheelEventCallback callback) const
  {
    if (! callback) return;

    log("sending");
    callback(target,
             deltaAxis1, deltaAxis2, deltaAxis3,
             fixedDelta1, fixedDelta2, fixedDelta3,
             pointDelta1, pointDelta2, pointDelta3,
             options, ts, sender, refcon);
  }
}
