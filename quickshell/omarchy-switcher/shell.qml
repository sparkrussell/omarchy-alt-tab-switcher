//@ pragma UseQApplication

// Thumbnail overlay for the Alt-Tab window switcher.
//
// State comes from ~/.config/hypr/switcher.lua over Hyprland's custom event
// channel; this process only renders it. Clicks and hovers are sent back by
// dispatching into the Lua table that module publishes.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

ShellRoot {
  id: root

  readonly property string channel: "omarchy-switcher>>"

  property bool shown: false
  // Window addresses in switcher order. Titles, classes and workspaces are
  // looked up from Hyprland.toplevels (windowFor), because Hyprland truncates
  // the custom event carrying this list at 1024 bytes.
  property var entries: []
  property int selected: 0
  property string monitor: ""

  readonly property var selectedEntry: root.selected >= 0 && root.selected < root.entries.length
    ? root.windowFor(root.entries[root.selected])
    : null

  // --- theme -----------------------------------------------------------------

  FileView {
    id: themeFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    onFileChanged: reload()
  }

  readonly property string themeSource: themeFile.text()

  function themeColor(key: string, fallback: string): string {
    const match = root.themeSource.match(new RegExp("^\\s*" + key + "\\s*=\\s*\"([^\"]+)\"", "m"));
    return match ? match[1] : fallback;
  }

  readonly property color accent: themeColor("accent", "#7aa2f7")
  readonly property color surface: themeColor("background", "#11121a")
  readonly property color surfaceAlt: themeColor("lighter_background", "#1a1b26")
  readonly property color textColor: themeColor("foreground", "#c0caf5")
  readonly property color textMuted: themeColor("dark_foreground", "#7f849c")

  // --- compositor plumbing ---------------------------------------------------

  function windowFor(address: string): var {
    const wanted = String(address).replace(/^0x/, "");
    return Hyprland.toplevels.values.find(t => String(t.address).replace(/^0x/, "") === wanted) || null;
  }

  function toplevelFor(address: string): var {
    const window = root.windowFor(address);
    return window ? window.wayland : null;
  }

  function dispatchLua(call: string): void {
    Hyprland.dispatch("omarchy_switcher." + call);
  }

  Connections {
    target: Hyprland

    function onRawEvent(event: HyprlandEvent): void {
      if (event.name !== "custom" || !event.data.startsWith(root.channel)) return;

      let payload;
      try {
        payload = JSON.parse(event.data.slice(root.channel.length));
      } catch (error) {
        console.warn("omarchy-switcher: bad payload", error, event.data);
        return;
      }

      if (!payload.open) {
        root.shown = false;
        return;
      }

      root.entries = payload.entries || [];
      root.selected = payload.sel || 0;
      root.monitor = payload.monitor || "";

      if (!root.shown) {
        // A window opened since Quickshell last listed toplevels would have no
        // capture source to bind to.
        Hyprland.refreshToplevels();
        root.shown = true;
      }
    }
  }

  // The overlay may be (re)started while a switcher is already up.
  Component.onCompleted: root.dispatchLua("resync()")

  // --- overlay ---------------------------------------------------------------

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: overlay
      required property var modelData

      screen: modelData
      visible: root.shown && (root.monitor === "" || root.monitor === modelData.name)

      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "omarchy-switcher"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"

      readonly property int cellWidth: Math.round(Math.max(190, Math.min(300, overlay.width * 0.135)))
      readonly property int cellHeight: Math.round(overlay.cellWidth * 0.72)
      readonly property int cellSpacing: 12
      readonly property int columns: Math.max(1, Math.min(root.entries.length,
        Math.floor((overlay.width * 0.92 + overlay.cellSpacing) / (overlay.cellWidth + overlay.cellSpacing))))

      // Mouse tracking only takes over selection once the pointer actually
      // moves, so a cursor parked over a thumbnail cannot hijack the keyboard.
      property bool pointerLive: false
      onVisibleChanged: overlay.pointerLive = false

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPositionChanged: overlay.pointerLive = true
        onClicked: root.dispatchLua("cancel()")

        Rectangle {
          id: backdrop
          color: "#66000000"
          anchors.fill: parent
        }

        Rectangle {
          id: card
          anchors.centerIn: parent
          width: grid.width + 32
          height: grid.height + 32
          radius: 20
          color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 0.88)
          border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.12)
          border.width: 1

          opacity: root.shown ? 1 : 0
          scale: root.shown ? 1 : 0.97
          Behavior on opacity { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
          Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

          Column {
            id: grid
            anchors.centerIn: parent
            spacing: 10

            Flow {
              id: flow
              spacing: overlay.cellSpacing
              width: overlay.columns * overlay.cellWidth + (overlay.columns - 1) * overlay.cellSpacing

              Repeater {
                model: root.entries

                delegate: Rectangle {
                  id: cell
                  required property var modelData
                  required property int index

                  readonly property var hyprWindow: root.windowFor(cell.modelData)
                  readonly property string appClass: cell.hyprWindow
                    ? (cell.hyprWindow.lastIpcObject.class || (cell.hyprWindow.wayland ? cell.hyprWindow.wayland.appId : ""))
                    : ""

                  readonly property bool current: cell.index === root.selected

                  width: overlay.cellWidth
                  height: overlay.cellHeight + 30
                  radius: 12
                  color: cell.current
                    ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                    : Qt.rgba(root.surfaceAlt.r, root.surfaceAlt.g, root.surfaceAlt.b, 0.55)
                  border.width: cell.current ? 2 : 1
                  border.color: cell.current
                    ? root.accent
                    : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.10)

                  Item {
                    id: thumbBox
                    anchors { top: parent.top; left: parent.left; right: parent.right }
                    anchors.margins: 6
                    height: overlay.cellHeight - 6

                    ScreencopyView {
                      id: thumb
                      anchors.centerIn: parent
                      // Capture only while shown. A hidden overlay (including one
                      // Variants builds for a monitor reconnecting on DPMS wake)
                      // would otherwise request toplevel frames for windows that
                      // have no monitor yet, which segfaults Hyprland 0.56.2
                      // (ScreenshareSession.cpp:85 dereferences a null monitor).
                      captureSource: root.shown ? root.toplevelFor(cell.modelData) : null
                      live: true
                      paintCursor: false

                      readonly property real aspect: thumb.sourceSize.height > 0
                        ? thumb.sourceSize.width / thumb.sourceSize.height
                        : 16 / 9
                      readonly property bool wide: thumb.aspect > thumbBox.width / thumbBox.height

                      width: thumb.wide ? thumbBox.width : thumbBox.height * thumb.aspect
                      height: thumb.wide ? thumbBox.width / thumb.aspect : thumbBox.height
                      opacity: thumb.hasContent ? 1 : 0
                    }

                    // Windows that refuse capture (or have not produced a frame
                    // yet) still need something to aim at.
                    Image {
                      anchors.centerIn: parent
                      visible: !thumb.hasContent
                      source: Quickshell.iconPath(cell.appClass, "application-x-executable")
                      sourceSize.width: 48
                      sourceSize.height: 48
                    }
                  }

                  Row {
                    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                    anchors.margins: 8
                    spacing: 6

                    Image {
                      width: 16
                      height: 16
                      anchors.verticalCenter: parent.verticalCenter
                      source: Quickshell.iconPath(cell.appClass, "application-x-executable")
                      sourceSize.width: 16
                      sourceSize.height: 16
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      // icon + both spacings + workspace badge
                      width: Math.max(0, parent.width - 16 - 12 - wsBadge.width)
                      elide: Text.ElideRight
                      text: cell.appClass || (cell.hyprWindow ? cell.hyprWindow.title : "")
                      color: cell.current ? root.textColor : root.textMuted
                      font.pixelSize: 12
                      font.bold: cell.current
                    }

                    Text {
                      id: wsBadge
                      anchors.verticalCenter: parent.verticalCenter
                      text: cell.hyprWindow && cell.hyprWindow.workspace ? cell.hyprWindow.workspace.name : ""
                      color: root.textMuted
                      font.pixelSize: 11
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: overlay.pointerLive = true
                    onEntered: {
                      if (overlay.pointerLive) root.dispatchLua("hover(\"" + cell.modelData + "\")");
                    }
                    onClicked: root.dispatchLua("pick(\"" + cell.modelData + "\")")
                  }
                }
              }
            }

            Text {
              width: flow.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideMiddle
              text: root.selectedEntry ? root.selectedEntry.title : ""
              color: root.textColor
              font.pixelSize: 13
            }
          }
        }
      }
    }
  }
}
