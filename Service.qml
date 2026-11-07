import QtQuick
import Quickshell.Io
import qs.Commons as Commons

// Omarchy shell plugin entry point (see manifest.json). Shows the HUD only
// while the Omarchy theme named "sentinel" is active.
Item {
  id: plugin

  // Set by the Omarchy shell host.
  property var shell: null
  property var manifest: null

  property string themeName: ""

  FileView {
    path: Commons.Color.stateHome + "/omarchy/current/theme.name"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: plugin.themeName = String(text() || "").trim()
  }

  Hud {
    active: plugin.themeName === "sentinel"
    reduceMotion: Commons.Style.reduceMotion
  }
}
