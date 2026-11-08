# 🌌 Depthscape

> Depth-aware occlusion and interactive 3D spatial wallpapers for **Dux Modular Shell (DMS)** on Wayland (Niri).

Depthscape estimates wallpaper depth locally to place desktop background widgets behind wallpaper subjects (iOS-style depth effect), and provides an interactive 3D spatial wallpaper mode that orbits with pointer motion.

---

### 🖼️ Depth Occlusion
![Depth Occlusion in action](assets/screenshot.png)

### 🧊 Spatial 3D Wallpaper
<video src="assets/screenrecord.mp4" controls width="100%"></video>

---

> [!WARNING]
> Desktop widget occlusion requires the background layer feature introduced in [dux-shell PR #4162](https://github.com/duxlabs-dev/dux-shell/pull/4162) (or DMS builds incorporating this branch). Standard DMS releases without background layer support will display widgets without occlusion.

---

## ✨ Features

- 🖼️ **Depth Occlusion**: Desktop background widgets sit naturally behind foreground wallpaper subjects.
- 🧊 **Interactive Spatial 3D**: Real-time 3D depth mesh and camera orbit driven by mouse pointer movement.
- 🧠 **Local & Offline Inference**: Powered by Depth Anything V2 (Small / Base / Large) and IS-Net Anime / BiRefNet. Models are downloaded **only on explicit user request**.
- 🖥️ **Per-Display Customization**: Independent controls for occlusion threshold, edge feathering, and spatial motion strength per monitor.

---

## 📋 Requirements

- **Dux Modular Shell (DMS)** 2.0+ (with [PR #4162](https://github.com/duxlabs-dev/dux-shell/pull/4162) desktop widget background layer support)
- **Niri** compositor (25.05+)
- **Rust & Cargo** (to compile the local depth engine)
- **Qt Quick3D** (for the 3D spatial mesh effect)

---

## ⚙️ Niri Configuration

Add the following rule to your Niri configuration (`~/.config/niri/config.kdl`):

```kdl
layer-rule {
    match namespace="^depthscape:"
    place-within-backdrop true
}
```

---

## 🚀 Quick Start

### 1. 📦 Install Plugin

Link Depthscape into your DMS plugins directory:

```bash
ln -s "$(pwd)" ~/.config/dms/plugins/depthscape
dms restart
```

### 2. 🛠️ Build the Engine

Build the Rust depth engine:

```bash
cd engine && cargo build --release
```

*(You can also click **Build Engine** directly inside the Depthscape plugin settings page).*

### 3. 🎛️ Configure & Download Model

Open **DMS Settings → Plugins → Depthscape**:

1. Select your preferred depth model (e.g. **Depth Anything V2 Small**) and click **Download Model**.
2. Turn on **Enable Depth Effect** to occlude desktop widgets.
3. Turn on **Spatial 3D Mesh Effect** to enable interactive 3D pointer parallax.

---

## 💻 Useful Commands

All features can be queried or triggered via DMS IPC:

```bash
# Re-analyze current wallpaper(s)
dms ipc call depthscape generate

# Query daemon status and surface health
dms ipc call depthscape debug

# Clear depth and spatial cache
dms ipc call depthscape clearCache

# Delete all downloaded models and cache data
dms ipc call depthscape uninstall
```

---

## 🙏 Acknowledgements & References

Depthscape builds upon ideas and implementations from the open-source community:

- **Depth Occlusion**: Inspired by [noctalia-dev/wallpaper_depth](https://github.com/noctalia-dev/official-plugins/tree/main/wallpaper_depth).
- **Spatial 3D Wallpaper**: 3D depth mesh and perspective pointer orbit implementation inspired by [NextKde/NextKde](https://github.com/NextKde/NextKde).

---

## 📄 License

MIT
