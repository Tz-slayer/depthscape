# Authoring Depthscape background widgets

A **background widget** is a widget Depthscape hosts on its own `background`
surface — one layer *below* DMS's `bottom`-layer desktop widgets — so the depth
mask can erase it wherever the wallpaper's subject stands in front of it.

Depthscape itself ships **no** background widget. It owns the surface, the mask
and the registry; deciding which widgets exist is the job of plugins — yours, or
someone else's. Every type resolves through the **registry**, so a widget is
added by registering it, never by touching the host:

* widgets contributed by **DMS plugins** (that is the only way in), and
* nothing else — there is no built-in path, and no type a plugin did not
  register can ever be placed.

---

## The core idea: a background widget must live inside the host

You might expect the clean design to be "publish the mask, let any widget
anywhere apply it". That was rejected on a correctness ground.

A background widget has to translate as a **rigid body** with the mask and the
wallpaper — the same oversized canvas margin, the same render-thread-animated
parallax offset, sampled through the same `OpacityMask`. A one-pixel desync
between the widget and the mask shows up as a halo or a "peel". Reproducing that
alignment inside a foreign surface owned by a different plugin is exactly the
fragile part.

So **a background widget is instantiated inside Depthscape's
`DepthBackgroundWidgetHost` canvas**, and this registry is how it gets there. What
you publish is not "my widget, occlude it yourself"; it is "here is a component
and its metadata, host it in your masked layer."

---

## The background widget contract

Your widget is a plain `Item`. The host positions it; the depth ordering does the
rest. Nothing in your widget knows about layers, surfaces, or the compositor.

Your `Item` **must** provide:

| Member | Type | Meaning |
|---|---|---|
| `settings` | `property var` | Injected by the host: the widget's registered `defaultConfig` merged under the per-instance `settings` from the layout file. Read from it, never assume your own defaults. |
| `editMode` | `property bool` | Injected by the host. When `true`, draw a subtle highlight so the widget is findable in the placement editor. Otherwise render as the user expects to see it on the desktop. |
| `palette` | `property var` | Injected by the host: the wallpaper-derived colour sidecar (`{ text, accent, secondary, average, isDark, luminanceGrid, gridSize, slots }`) or `null` when none is available yet. Optional to *use*, but your `Item` must **declare** `property var palette: null`, because the host binds it into every widget uniformly. A widget that wants wallpaper-themed colour reads it (see `DepthClockWidget`'s `colorMode`); one that does not can ignore it. |
| `localLuma` | `property real` | Injected by the host: the WCAG relative luminance (0..1) of the region directly behind *this* widget, sampled from `palette.luminanceGrid`. `NaN` when there is no grid. Declared (unused is fine) for the same reason as `palette` — the host binds it into every widget; a colour-aware widget uses it for local contrast (see `DepthAutoColor.js`). |
| `implicitWidth` / `implicitHeight` | size | The host sizes its holder from these. Report a real preferred size. |


### Hard rules (these come from the surface, not from taste)

1. **Decorative and click-through-safe.** The host surface has an empty input
   region (`mask: Region {}`) — your widget receives **no** mouse or keyboard
   events outside the placement editor. Anything that requires interaction does
   not belong here.
2. **Do not assume you fill the screen.** You are placed by top-left in *screen*
   coordinates and sized to your `implicitWidth/Height`.
3. **Design for disappearing.** Your widget can be fully or partially erased by
   the mask at any scroll position. Do not carry information the user cannot get
   elsewhere; a glanceable read-out is the sweet spot.
4. **No background card** unless `editMode`. A filled panel reads as a desktop
   widget rather than something the subject stands in front of. Draw the card
   only while `editMode` is true.

---

## The widget definition

Registration takes a small object. Only `id` and `component` are required.

```js
{
    id: "myplugin.calendar",       // unique, namespaced (see "id format")
    component: Qt.resolvedUrl("./CalendarWidget.qml"), // URL or Component
    name: "Calendar",              // shown in any picker UI
    icon: "calendar_today",
    description: "Month grid that dives behind the subject.",
    defaultConfig: { weekStart: 1 }, // merged UNDER per-instance settings
    provider: "myplugin"           // your pluginId; enables auto-cleanup
}
```

`component` is resolved **by your code** in **your** QML import scope, so
`Qt.resolvedUrl("./CalendarWidget.qml")` points at a file shipped inside your
own plugin directory. This is what keeps the data file inert (see *Security*).

### `id` format

A namespaced token: lowercase letters, digits, and `.`/`_`/`-` separators, e.g.
`myplugin.calendar`. The regex enforced is
`/^[a-z0-9]+([._-][a-z0-9]+)*$/`. Namespacing stops two plugins colliding on a
bare `clock`.

`depthscape.` is the one prefix Depthscape uses for itself — it ships a set of
built-in types under that prefix (currently `depthscape.clock`, `depthscape.motto`
and `depthscape.calendar`). Claim it and you would collide with them; use your
own pluginId.

The built-ins are registered through the very same `registerBackgroundWidget()`
call documented below, with `provider: "depthscape"`. There is no separate
built-in code path, and nothing about them is privileged — they are default
suppliers, not special cases in the host. See `qml/builtins/DepthBuiltinWidgets.qml`
and `qml/builtins/DepthClockWidget.qml`, which double as the reference
implementation of this contract.

---

## Public API — `DepthBackgroundWidgetRegistry`

Reach it at `pluginService.pluginInstances["depthscape"].backgroundWidgetRegistry`.

| Call | Returns | Notes |
|---|---|---|
| `registerBackgroundWidget(def)` | `bool` | Adds or replaces `def.id`. `false` if `id`/`component` missing or `id` malformed. |
| `unregisterBackgroundWidget(id)` | — | Remove one. No-op if absent. |
| `unregisterBackgroundWidgetsByProvider(pluginId)` | — | Remove everything one plugin contributed (also called for you on unload). |
| `isRegistered(id)` | `bool` | |
| `get(id)` | `object\|null` | The stored entry. |
| `componentFor(id)` | `url\|Component\|""` | `""` when unknown; the host renders nothing for that entry. |
| `defaultConfigFor(id)` | `object` | `{}` when unknown. |
| `schemaFor(id)` | `array` | The type's `configSchema`, `[]` when it declared none. |
| `all()` | `array` | All entries sorted by `name`. For a picker. |
| `registryChanged()` | *signal* | Fires after any register/unregister. |

Re-registering the same `id` replaces it in place; already-placed instances of
that type re-resolve on the next `registryChanged`.

#### `configSchema` — making a type editable in the settings page

`defaultConfig` says what the values are; `configSchema` says how a person edits
them. It is an optional array on the registration:

```qml
configSchema: [
    { key: "weekStart", label: "First day of week", kind: "number",
      min: 0, max: 6, step: 1 },
    { key: "bold", label: "Bold digits", kind: "bool" },
    { key: "accent", label: "Accent colour", kind: "color" },
    { key: "format", label: "Format string", kind: "text" }
]
```

* `kind` is `"number"`, `"bool"`, `"color"`, `"text"`, `"select"` or `"font"`. Anything else is
  dropped, as is any entry without a `key`.
* `"select"` takes `options` (a string array) and renders a dropdown; `"font"` renders a
  dropdown of every font family Qt can see.
* `number` takes optional `min`, `max`, `step` (integer — the slider is
  integer-only) and `scale`: `stored = shown * scale`, which is how a `0-1`
  ratio is presented as a `0-100` percentage.
* The settings page renders one control per entry and nothing else. A key you
  leave out stays editable in `widgets.json` only, and a type with no schema at
  all still works — it just shows position and a remove button.
* Position (`x`/`y`) is never part of the schema: it is a layout property every
  type shares, and the page always shows it.

---

## Registering from another plugin

You contribute the widget; you do **not** own a surface. Depend on Depthscape
softly — if it is not installed or not loaded yet, do nothing and degrade
gracefully.

```qml
// In your plugin's daemon (a PluginComponent), which already has `pluginService`.
Connections {
    target: root.pluginService

    // Cover both orders: Depthscape may load before OR after you.
    function onPluginLoaded(loadedId) {
        if (loadedId === "depthscape")
            root.contributeWidgets();
    }
}

Component.onCompleted: {
    // Maybe Depthscape is already up when you load.
    root.contributeWidgets();
}

function contributeWidgets() {
    const ds = root.pluginService && root.pluginService.pluginInstances
        ? root.pluginService.pluginInstances["depthscape"]
        : null;
    if (!ds || !ds.backgroundWidgetRegistry)
        return;                       // Depthscape absent: skip silently

    const ok = ds.backgroundWidgetRegistry.registerBackgroundWidget({
        id: "myplugin.calendar",
        component: Qt.resolvedUrl("./CalendarWidget.qml"),
        name: "Calendar",
        icon: "calendar_today",
        description: "A month grid that dives behind the wallpaper subject.",
        defaultConfig: { weekStart: 1 },
        // Optional: what the settings page shows. Leave it out and the type is
        // still placeable, just editable only in widgets.json.
        configSchema: [
            { key: "weekStart", label: "First day of week", kind: "number",
              min: 0, max: 6, step: 1 }
        ],
        provider: root.pluginId        // your pluginId — enables auto-cleanup
    });
    if (!ok)
        console.warn("myplugin: Depthscape rejected the calendar widget");
}
```

Notes:

* **Both load orders are covered.** `onPluginLoaded("depthscape")` handles
  Depthscape coming up after you; `Component.onCompleted` handles it already
  being up. `registerBackgroundWidget` is idempotent per `id`, so firing twice is
  safe.
* **Cleanup is automatic.** Depthscape listens for `pluginUnloaded` and calls
  `unregisterBackgroundWidgetsByProvider(yourId)`, so your widgets vanish with
  your plugin and
  never linger as broken layout entries. You do not have to unregister yourself
  (though you may, for a sub-feature).
* Pass your **own** `pluginId` as `provider`, not `"depthscape"`.

---

## How a user places your widget

Nothing to do per plugin — Depthscape's single layout file lists instances by
registered type. Users edit the `widgets.json` next to plugin.json (the
settings page points at it and the host hot-reloads it):

```json
{
    "widgets": [
        { "id": "cal-main",   "type": "myplugin.calendar",  "x": 200,  "y": 200, "name": "Calendar", "settings": { "weekStart": 0 } },
        { "id": "clock-main", "type": "depthscape.clock",   "x": 1100, "y": 850, "occlude": false, "settings": { "showSeconds": false } }
    ]
}
```

* `type` **must** equal a registered `id`. An unregistered `type` renders nothing
  (and logs a warning) — it never loads an arbitrary path.
* `id` is unique per instance; the layer list and the settings page use it.
* `name` overrides the type's registered name for this instance. Omit it and the
  type name is used; a repeated type gets a numeric suffix automatically.
* `visible: false` hides the instance while keeping its row in the layer list.
* `occlude: false` opts the widget out of the depth mask: it draws above the
  masked group and is never erased by the wallpaper's near plane.
* `pinned: true` pins the widget to the screen: it does not follow the 3D
  parallax, but the mask still moves with the wallpaper, so the subject can
  still erase it. While pinned, `occlude` is ignored.
* `x`/`y` are logical pixels from the output's top-left, clamped on screen.
  Optional `anchorX` (`left`/`center`/`right`) and `anchorY` (`top`/`center`/
  `bottom`) reinterpret them as the position of that edge or centre, so a widget
  whose size changes stays centred. Both default to the top-left.
* `settings` is shallow-merged **over** the widget's `defaultConfig`.
* Omitting `screen` shows the widget on every output; set `screen` to one output
  name to pin it.
* Array order is paint order (later entries draw above earlier ones). The layer
  list shows the reverse, top-most first; dragging a row rewrites this order.

---

## Security invariant (do not break it)

The layout file lives in the user's writable data directory. It may reference a
widget **only by a registered id**. A `type` string is never treated as a file
path or URL. The component URL exists solely in code that calls
`registerBackgroundWidget`, resolved in the registering plugin's own import
scope. This is
deliberate and mirrors DMS's own `DesktopWidgetRegistry` (resource paths, never
data-file paths): it prevents a hand-edited `widgets.json` from turning itself
into arbitrary code execution.

---

## There is no built-in path

Depthscape registers no types of its own, so there is no "add a built-in" step:
if you want a widget, it goes in a plugin, and the snippet under *Registering
from another plugin* is the whole story. Depthscape used to ship a clock and
dropped it — whether a clock shows seconds has nothing to do with a masked
surface, and answering that inside Depthscape made the host a tenant of its own
platform. A plugin has no special status and cannot be half-internal, which is
what makes the contract stay honest.

Practical consequence: with no widget plugin installed, the registry is empty,
`widgets.json` has no `type` it can resolve, and the desktop shows wallpaper
only. That is the expected state, not a fault.

---

## Author's checklist

- [ ] `Item` reads everything from `settings`, never hard-coded values.
- [ ] Declares `property var palette: null` even if unused, so the host's
      uniform injection does not error.
- [ ] `editMode` shows a placement highlight; normal mode has no card.
- [ ] Real `implicitWidth`/`implicitHeight`.
- [ ] No reliance on mouse/keyboard input.
- [ ] Registered `id` is namespaced with your own pluginId
      (`yourplugin.thing`) — `depthscape.` is taken by the built-in widgets.
- [ ] Every `settings` key has a fallback, so a layout entry naming only the
      type still renders.
- [ ] Registration is guarded (Depthscape may be absent) and covers both load
      orders.
- [ ] You pass your own `pluginId` as `provider`.
- [ ] You verified it against a wallpaper with a clear foreground subject, so
      the occlusion actually bites.
