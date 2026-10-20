# 📱 Android Duo — Полная инструкция пользователя

Подробная текстовая инструкция на русском языке находится в файле:
👉 [ИНСТРУКЦИЯ.md](ИНСТРУКЦИЯ.md)

---

# 📱 Android Duo — Quick User Guide (English Summary)

**Android Duo** turns your Android tablet (such as Xiaomi Redmi Pad SE) into a high-performance second monitor for your Mac with **90 Hz**, ultra-low latency (**2–5 ms** via USB), and macOS multitouch gesture support.

## ⚡ Modes
- **USB Cable:** 90 Hz / 90 FPS, 2–5 ms latency, charges tablet, highest smoothness.
- **Wi-Fi:** 60 Hz / 60 FPS, 10–25 ms latency, seamless wireless fallback.
- **Auto-Switch:** Seamless failover to Wi-Fi when cable is unplugged, instant promotion back to USB (90 FPS) when cable is replugged.

## 🛠 Initial Setup (One-time)
1. **Tablet Developer Options:**
   - Tap **OS Version / MIUI Version** 7 times in *Settings → About tablet*.
   - Enable **USB Debugging** in *Settings → Additional settings → Developer options*.
   - **Crucial for Type-C ↔ Type-C cables:** Set **Default USB configuration** to **File Transfer (MTP)** so the Mac is always the USB Host.
   - Set tablet screen refresh rate to **90 Hz** in *Settings → Display → Refresh rate*.
2. **Mac Permissions:**
   - Grant **Screen Recording** permission to Android Duo in *System Settings → Privacy & Security → Screen Recording*.
   - In *System Settings → Privacy & Security → Allow accessories to connect*, select **Automatically**.
3. **Install APK:**
   - Install `Android Duo.apk` located in the root folder via `adb install -r "Android Duo.apk"` or by copying it to the tablet.

## 🚀 Daily Usage
- Plug Type-C cable → Display activates instantly at **⚡ 90 FPS**.
- Unplug cable → Stream continues wirelessly over **📶 Wi-Fi 60 FPS**.
- Replug cable → Upgrades back to **⚡ USB 90 FPS** within 1 second.

## 🛡 Battery Guard & Power Management
- **Zero Sound Spam:** Silent battery polling avoids repetitive "Charging started" chimes on HyperOS / Android 15.
- **Hardware 80% Protection Shortcut:** One click in the Mac dashboard/menu bar opens the native HyperOS battery protection activity on the tablet to hardware-limit charging to 80%.
- **Remote Sleep / Wake:** Put the tablet screen to sleep or wake it up instantly from the macOS Menu Bar.

## 🔄 Portrait Mode & Live Hardware Monitor
- **Auto-Rotation & Portrait Mode:** Flip your tablet vertically for 100+ lines of code without scrolling. Controlled under UI Scaling settings with Auto, Landscape, and Portrait modes.
- **Live Hardware Monitor:** Real-time Apple Silicon M1/M2 CPU %, RAM usage, network stream bitrate, temperature, and both device batteries.
