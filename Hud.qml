import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Live readouts drawn on the desktop, under every window. Everything shown is
// read from the system by hud.sh and netmap.sh; nothing is decorative text.
// View-only: the layer takes no input and clicks pass straight through.
//
// Portable core: no Omarchy imports. shell.qml runs it under plain
// Quickshell; Service.qml wraps it as an Omarchy shell plugin.
Item {
  id: root

  // Whether the HUD is drawn and polling. Wrappers bind this.
  property bool active: true
  // Skip animations (Omarchy passes its reduce-motion setting through).
  property bool reduceMotion: false

  function script(name) { return decodeURIComponent(Qt.resolvedUrl(name).toString().replace("file://", "")) }
  property var d: ({})
  property var net: ({})

  readonly property color blue: "#2f9bff"
  readonly property color cyan: "#3fe0ff"
  readonly property color red: "#ff4f6a"
  readonly property color green: "#3ff2a8"
  readonly property color amber: "#ffcf5c"
  readonly property color dim: "#5b7088"
  readonly property color text: "#9fb7cc"
  readonly property string mono: "JetBrainsMono Nerd Font"

  Process {
    id: hudProc
    command: [root.script("hud.sh")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.d = JSON.parse(String(text || "{}")) } catch (e) {} }
    }
  }
  Process {
    id: netProc
    command: [root.script("netmap.sh")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.net = JSON.parse(String(text || "{}")) } catch (e) {} }
    }
  }
  Timer {
    interval: 3000; running: root.active; repeat: true; triggeredOnStart: true
    onTriggered: if (!hudProc.running) hudProc.running = true
  }
  Timer {
    interval: 5000; running: root.active; repeat: true; triggeredOnStart: true
    onTriggered: if (!netProc.running) netProc.running = true
  }

  // ── formatting helpers ──
  function rate(b) {
    b = Number(b || 0)
    if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB/s"
    if (b >= 1024) return (b / 1024).toFixed(0) + " KB/s"
    return b + " B/s"
  }
  function uptime(s) {
    s = Number(s || 0)
    var dd = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
    return (dd ? dd + "d " : "") + h + "h " + m + "m"
  }
  function bar(p) {
    var n = Math.round(Math.max(0, Math.min(100, Number(p || 0))) / 10)
    return "█".repeat(n) + "░".repeat(10 - n)
  }
  function pct(v, unit) { return String(Math.round(Number(v || 0))).padStart(3) + (unit || "%") }
  function level(p, warn, crit) { return p >= crit ? red : p >= warn ? amber : cyan }
  function spark(a) {
    a = a || []
    var ticks = "▁▂▃▄▅▆▇█", max = Math.max.apply(null, a.concat([1]))
    return a.map(function(v) { return v === 0 ? "·" : ticks[Math.min(7, Math.ceil(v / max * 7))] }).join("")
  }
  function ago(s) { return s < 60 ? s + "s ago" : Math.floor(s / 60) + "m ago" }

  component Line: Text {
    textFormat: Text.PlainText
    font.family: root.mono
    font.pixelSize: 10
    color: root.text
    elide: Text.ElideRight
  }
  component Head: Line { color: root.blue; font.pixelSize: 11; font.bold: true; topPadding: 5 }
  component KV: Row {
    property string k
    property string v
    property color vc: root.text
    property int vw: 168
    property bool alignEnd: false
    spacing: 6
    Line { text: parent.k; color: root.dim; width: 62 }
    Line { text: parent.v; color: parent.vc; width: parent.vw; horizontalAlignment: parent.alignEnd ? Text.AlignRight : Text.AlignLeft }
  }

  Variants {
    model: root.active ? Quickshell.screens : []

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      color: "transparent"
      WlrLayershell.namespace: "sentinel-hud"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Normal
      anchors { top: true; bottom: true; left: true; right: true }
      mask: Region {}

      // ── top-left: identity · network · dns ──
      Column {
        x: 40; y: 20; spacing: 2
        Head { text: "// " + (root.d.user || "") + "@" + (root.d.host || ""); topPadding: 0 }
        KV { k: "kernel"; v: root.d.kernel || "" }
        KV { k: "uptime"; v: root.uptime(root.d.up) }
        Head { text: "NETWORK" }
        KV { k: "link"; v: (root.d.dev || "offline") + (root.d.ssid ? "  " + root.d.ssid : ""); vc: root.d.dev ? root.text : root.red }
        KV { k: "addr"; v: root.d.ip || "—" }
        KV { k: "gateway"; v: root.d.gw || "—" }
        KV { k: "rx / tx"; v: root.rate(root.d.rx) + " ↓  " + root.rate(root.d.tx) + " ↑" }
        KV { k: "tunnel"; v: root.d.vpn || "none"; vc: root.d.vpn ? root.green : root.dim }
        KV { k: "dns"; v: root.d.dns || "—" }
        KV {
          k: "dns-tls"
          v: root.d.dot === "+DNSOverTLS" ? "encrypted" : "plaintext"
          vc: root.d.dot === "+DNSOverTLS" ? root.green : root.amber
        }
      }

      // ── top-right: load · disk · power ──
      Column {
        anchors.right: parent.right; anchors.rightMargin: 40; y: 20; spacing: 2
        width: 236
        property bool isRight: true
        Head { width: parent.width; horizontalAlignment: Text.AlignRight; text: "SYSTEM LOAD"; topPadding: 0 }
        KV { alignEnd: true; k: "cpu"; v: root.bar(root.d.cpu) + root.pct(root.d.cpu); vc: root.level(root.d.cpu, 70, 90) }
        KV { alignEnd: true; k: "mem"; v: root.bar(root.d.mem) + root.pct(root.d.mem); vc: root.level(root.d.mem, 75, 90) }
        KV { alignEnd: true; k: "temp"; v: root.bar(root.d.temp) + root.pct(root.d.temp, "°"); vc: root.level(root.d.temp, 75, 90) }
        KV { alignEnd: true; k: "loadavg"; v: root.d.load || "" }
        Head { width: parent.width; horizontalAlignment: Text.AlignRight; text: "STORAGE" }
        Repeater {
          model: root.d.disks || []
          KV { alignEnd: true;
            required property var modelData
            k: modelData.mount
            v: root.bar(modelData.pct) + root.pct(modelData.pct) + " " + String(modelData.gb + "G").padStart(5)
            vc: root.level(modelData.pct, 80, 92)
          }
        }
        Head { width: parent.width; horizontalAlignment: Text.AlignRight; text: "POWER"; visible: (root.d.bat ?? -1) >= 0 }
        KV { alignEnd: true;
          visible: (root.d.bat ?? -1) >= 0
          k: "battery"
          v: root.bar(root.d.bat) + root.pct(root.d.bat)
          vc: root.d.batState === "Discharging" && root.d.bat <= 15 ? root.red
            : root.d.batState === "Discharging" && root.d.bat <= 30 ? root.amber : root.green
        }
        KV { alignEnd: true;
          visible: (root.d.bat ?? -1) >= 0
          k: "state"
          v: (root.d.batState || "").toLowerCase() + (root.d.batWatts > 0 ? "  " + (root.d.batWatts / 10).toFixed(1) + " W" : "")
        }
      }

      // ── bottom-right: security posture ──
      Column {
        anchors.right: parent.right; anchors.rightMargin: 40
        anchors.bottom: parent.bottom; anchors.bottomMargin: 20; spacing: 2
        width: 236
        property bool isRight: true
        Head { width: parent.width; horizontalAlignment: Text.AlignRight; text: "SECURITY POSTURE" }
        KV { alignEnd: true; k: "firewall"; v: "ufw " + (root.d.fw || "unknown"); vc: root.d.fw === "active" ? root.green : root.red }
        KV { alignEnd: true; k: "sessions"; v: String(root.d.estab || 0) + " established tcp" }
        KV { alignEnd: true; k: "auth fail"; v: String(root.d.authfail || 0) + " today"; vc: root.d.authfail > 0 ? root.red : root.green }
        KV { alignEnd: true; k: "units"; v: root.d.failed ? "failed: " + root.d.failed : "all healthy"; vc: root.d.failed ? root.red : root.green }
        Head { width: parent.width; horizontalAlignment: Text.AlignRight; text: "FIREWALL BLOCKS · 1h" }
        KV { alignEnd: true;
          k: String(root.d.fwstats ? root.d.fwstats.total : 0) + " total"
          v: root.spark(root.d.fwstats ? root.d.fwstats.spark : []) + "  now"
          vc: root.d.fwstats && root.d.fwstats.total > 0 ? root.red : root.green
        }
        Repeater {
          model: root.d.fwstats ? root.d.fwstats.top : []
          KV { alignEnd: true;
            required property var modelData
            k: "×" + modelData.n
            v: modelData.src + "  " + modelData.port
            vc: root.red
          }
        }
        Head { width: parent.width; horizontalAlignment: Text.AlignRight; text: "LISTENING · reachable from network" }
        Line { width: parent.width; horizontalAlignment: Text.AlignRight; text: "nothing exposed"; color: root.green; visible: !(root.d.listen && root.d.listen.length) }
        Repeater {
          model: (root.d.listen || []).slice(0, 6)
          KV { alignEnd: true;
            required property var modelData
            k: modelData.proto + "/" + modelData.port
            v: modelData.proc
            vc: root.amber
          }
        }
      }

      // ── bottom-left: journal · updates · repos ──
      Column {
        x: 40; anchors.bottom: parent.bottom; anchors.bottomMargin: 20; spacing: 2
        Head { text: "JOURNAL · warnings + firewall" }
        Repeater {
          model: root.d.log || []
          Row {
            required property var modelData
            spacing: 8
            Line { text: modelData.t; color: root.dim }
            Line { width: 250; text: modelData.msg; color: modelData.kind === "fw" ? root.red : root.text }
          }
        }
        Head { text: "UPDATES" }
        KV {
          k: "pacman"
          v: (root.d.updates ?? -1) < 0 ? "checking…" : root.d.updates === 0 ? "up to date" : root.d.updates + " pending"
          vc: root.d.updates > 0 ? root.amber : root.green
        }
        KV {
          k: "security"
          v: (root.d.secUpdates ?? -1) < 0 ? "arch-audit not installed" : root.d.secUpdates === 0 ? "no advisories" : root.d.secUpdates + " fixable advisories"
          vc: (root.d.secUpdates ?? -1) < 0 ? root.dim : root.d.secUpdates > 0 ? root.red : root.green
        }
        KV { k: "checked"; v: root.ago(root.d.updAge || 0); vc: root.dim }
        Head { text: "REPOS" }
        Line { text: "no git repos under " + (root.d.repoRoots || "the configured roots"); color: root.dim; visible: !(root.d.repos && root.d.repos.length) }
        Repeater {
          model: root.d.repos || []
          KV {
            required property var modelData
            k: modelData.name
            v: modelData.branch + "  " + modelData.ab + (modelData.dirty ? "  ✎" + modelData.dirty : "  clean")
            vc: modelData.dirty ? root.amber : root.green
          }
        }
      }

      // ── centre: network map ──
      NetMap {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: 10
        width: 480; height: 480
        net: root.net
        hud: root
      }
    }
  }
}
