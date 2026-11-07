import QtQuick

// The network as this machine sees it, drawn from netmap.sh:
//   this host in the middle, LAN devices on the arc below it, the gateway
//   above, and remote hosts (grouped by domain) fanned out past the gateway.
//   Cyan lines carry live TCP connections, with a pulse travelling along them.
//   Red lines are firewall blocks from that host, fading over the block window.
//   Amber marks a device first seen in the last 24 hours.
Item {
  id: map

  property var net: ({})
  property var hud: null

  readonly property real cx: width / 2
  readonly property real cy: height / 2 + 24
  readonly property real gwX: cx
  readonly property real gwY: cy - 96
  readonly property int window: net.window || 600

  function blockAlpha(age) { return age < 0 ? 0 : Math.max(0.15, 1 - age / window) }

  // Lay out nodes once per data refresh.
  readonly property var placed: {
    var out = []
    if (!net.online) return out
    var lan = (net.lan || []).filter(function(n) { return n.kind !== "gateway" })
    var gw = (net.lan || []).filter(function(n) { return n.kind === "gateway" })[0]
    out.push({ id: "gw", kind: "gateway", x: gwX, y: gwY, px: cx, py: cy,
               label: gw ? gw.label : "gateway", sub: net.gw || "", conns: gw ? gw.conns : 0,
               blocked: gw ? gw.blocked : -1, port: gw ? gw.port : "", isnew: false })

    // LAN: lower arc around this host, alternating two radii so labels clear.
    var n = lan.length
    for (var i = 0; i < n; i++) {
      var a = (n === 1 ? 90 : -6 + 192 * i / (n - 1)) * Math.PI / 180
      var r = [112, 152, 190][i % 3]
      var d = lan[i]
      out.push({ id: d.id, kind: "lan", x: cx + r * 1.0 * Math.cos(a), y: cy + r * 0.86 * Math.sin(a), px: cx, py: cy,
                 label: d.label, sub: d.label === d.ip ? (d.vendor || "") : d.ip,
                 conns: d.conns, blocked: d.blocked, port: d.port, isnew: d.isnew })
    }

    // Remote: upper fan beyond the gateway.
    var wan = net.wan || []
    var m = wan.length
    for (var j = 0; j < m; j++) {
      var b = (m === 1 ? 270 : 198 + 144 * j / (m - 1)) * Math.PI / 180
      var rr = (j % 2 === 0) ? 112 : 148
      var w = wan[j]
      out.push({ id: w.id, kind: "wan", x: gwX + rr * Math.cos(b), y: gwY + rr * 0.85 * Math.sin(b), px: gwX, py: gwY,
                 label: w.label, sub: w.blocked >= 0 && !w.conns ? "blocked " + w.port
                        : (w.conns + " conn" + (w.conns === 1 ? "" : "s") + (w.hosts > 1 ? " · " + w.hosts + " hosts" : "")),
                 conns: w.conns, blocked: w.blocked, port: w.port, isnew: false })
    }
    return out
  }

  // ── links + pulses ──
  Canvas {
    id: links
    anchors.fill: parent
    property real phase: 0
    onPaint: {
      var g = getContext("2d")
      g.reset()
      var nodes = map.placed
      for (var i = 0; i < nodes.length; i++) {
        var nd = nodes[i]
        var blocked = nd.blocked >= 0
        var live = nd.conns > 0 || nd.kind === "gateway"
        g.beginPath()
        g.moveTo(nd.px, nd.py)
        g.lineTo(nd.x, nd.y)
        if (blocked) {
          g.strokeStyle = Qt.rgba(1, 0.31, 0.42, map.blockAlpha(nd.blocked))
          g.lineWidth = 2
          g.setLineDash([6, 4])
        } else if (live) {
          g.strokeStyle = Qt.rgba(0.25, 0.88, 1, 0.55)
          g.lineWidth = 1.6
          g.setLineDash([])
        } else {
          g.strokeStyle = Qt.rgba(0.18, 0.61, 1, 0.16)
          g.lineWidth = 1
          g.setLineDash([])
        }
        g.stroke()
        g.setLineDash([])

        // A pulse runs outward along live links, inward along blocked ones.
        if (live || blocked) {
          var t = (phase + i * 0.137) % 1
          if (blocked) t = 1 - t
          g.beginPath()
          g.arc(nd.px + (nd.x - nd.px) * t, nd.py + (nd.y - nd.py) * t, blocked ? 2.5 : 2, 0, Math.PI * 2)
          g.fillStyle = blocked ? Qt.rgba(1, 0.31, 0.42, map.blockAlpha(nd.blocked)) : Qt.rgba(0.6, 0.95, 1, 0.9)
          g.fill()
        }
      }
    }
    Connections { target: map; function onPlacedChanged() { links.requestPaint() } }
    Timer {
      interval: 50; repeat: true; running: map.visible && map.placed.length > 0
      onTriggered: { links.phase = (links.phase + 0.02) % 1; links.requestPaint() }
    }
  }

  // ── this host ──
  Rectangle {
    x: map.cx - 7; y: map.cy - 7; width: 14; height: 14; radius: 7
    color: "#06101c"; border.color: map.hud.cyan; border.width: 2
  }
  Column {
    x: map.cx + 12; y: map.cy - 11
    Text { textFormat: Text.PlainText; font.family: map.hud.mono; font.pixelSize: 10; font.bold: true; color: map.hud.cyan; text: map.net.host || "" }
    Text { textFormat: Text.PlainText; font.family: map.hud.mono; font.pixelSize: 8; color: map.hud.dim; text: map.net.ip || "" }
  }

  // ── nodes ──
  Repeater {
    model: map.placed
    Item {
      required property var modelData
      readonly property bool blocked: modelData.blocked >= 0
      readonly property color tint: blocked ? map.hud.red
        : modelData.isnew ? map.hud.amber
        : modelData.kind === "wan" ? map.hud.cyan
        : map.hud.blue
      x: modelData.x; y: modelData.y
      // Only hosts that are on the map *because* of a block fade with it.
      opacity: blocked && (modelData.kind === "wan" ? !modelData.conns : modelData.sub === "") ? map.blockAlpha(modelData.blocked) : 1
      Behavior on opacity { NumberAnimation { duration: map.hud.reduceMotion ? 0 : 180; easing.type: Easing.OutCubic } }

      Rectangle {
        readonly property int s: modelData.kind === "gateway" ? 11 : modelData.kind === "wan" ? 7 : 7
        x: -s / 2; y: -s / 2; width: s; height: s
        radius: modelData.kind === "wan" ? 2 : s / 2
        rotation: modelData.kind === "wan" ? 45 : 0
        color: modelData.conns > 0 || modelData.kind === "gateway" ? tint : "#06101c"
        border.color: tint; border.width: 2
      }
      Column {
        readonly property bool above: modelData.y < map.cy - 40
        x: -width / 2
        y: above ? -height - 7 : 7
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(implicitWidth, 84)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText; elide: Text.ElideRight
          font.family: map.hud.mono; font.pixelSize: 8
          color: parent.parent.tint
          text: (modelData.isnew ? "NEW " : "") + modelData.label
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(implicitWidth, 84)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText; elide: Text.ElideRight
          font.family: map.hud.mono; font.pixelSize: 7
          color: parent.parent.blocked ? map.hud.red : map.hud.dim
          text: parent.parent.blocked && modelData.kind !== "wan" ? "blocked " + modelData.port : modelData.sub
          visible: text !== ""
        }
      }
    }
  }

  // ── header + legend ──
  Column {
    anchors.horizontalCenter: parent.horizontalCenter
    y: 0
    spacing: 2
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText; font.family: map.hud.mono; font.pixelSize: 11; font.bold: true
      color: map.net.online === false ? map.hud.red : map.hud.blue
      text: map.net.online === false ? "NETWORK · offline"
        : "NETWORK · " + (map.net.net || "") + " · " + (map.net.lan || []).length + " hosts"
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText; font.family: map.hud.mono; font.pixelSize: 8
      color: map.net.sweep === "off" ? map.hud.dim : map.hud.amber
      text: map.net.sweep === "off" ? "passive discovery"
        : map.net.sweep === "running" ? "passive + sweep in progress" : "passive + ping sweep every 5m"
    }
  }
  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    spacing: 14
    Repeater {
      model: [
        { c: map.hud.blue, t: "● lan" },
        { c: map.hud.amber, t: "● new 24h" },
        { c: map.hud.cyan, t: "◆ remote" },
        { c: map.hud.cyan, t: "━ live tcp" },
        { c: map.hud.red, t: "╍ fw block" }
      ]
      Text {
        required property var modelData
        textFormat: Text.PlainText; font.family: map.hud.mono; font.pixelSize: 8
        color: modelData.c; text: modelData.t; opacity: 0.8
      }
    }
  }
}
