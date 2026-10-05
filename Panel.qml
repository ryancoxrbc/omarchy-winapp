import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for the Windows VM behind the bundled `winapp` command. The icon
// is dim while the VM is off; the panel opens Windows apps (booting the VM
// first when needed), switches the VM on and off, and sets how long it lingers
// after the last app window closes. Everything it shows comes from
// `winapp state`, and everything it does is a `winapp` command.
Panel {
  id: win
  moduleName: "ryancoxrbc.winapp"
  ipcTarget: "ryancoxrbc.winapp"
  manageIpc: false

  readonly property string bundled: Qt.resolvedUrl("bin/winapp").toString().replace(/^file:\/\//, "")
  readonly property string command: {
    var custom = String(setting("command", "") || "").trim()
    return custom !== "" ? custom : bundled
  }
  readonly property bool hideWhenStopped: setting("hideWhenStopped", false) === true

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Material Design glyphs from the bar's Nerd Font
  readonly property string glyphWindows: String.fromCodePoint(0xF05B3)
  readonly property string glyphDesktop: String.fromCodePoint(0xF0379)
  readonly property string glyphApps: String.fromCodePoint(0xF003B)
  readonly property string glyphInstall: String.fromCodePoint(0xF01DA)
  readonly property string glyphChip: String.fromCodePoint(0xF035B)

  // --- state, as reported by `winapp state` -----------------------------------
  property bool installed: true
  property string vm: "stopped"        // stopped | starting | running | stopping
  property int windows: 0
  property bool desktop: false         // the full desktop is open; apps cannot be
  property int idleMinutes: 5
  property real idleDeadline: 0        // epoch seconds, 0 = no countdown
  property real clockOffset: 0         // helper clock minus ours, in seconds
  property int idleLeft: 0
  property var apps: []
  property string ram: ""              // "16G", empty when not known
  property string cores: ""
  property string lastError: ""
  // What was just asked for, until the helper's own state catches up.
  property string pending: ""          // "" | "start" | "stop"
  property bool confirmStop: false

  readonly property bool off: vm === "stopped" && pending !== "start"
  readonly property bool busy: vm === "starting" || vm === "stopping" || pending !== ""
  readonly property bool on: !off && vm !== "stopping" && pending !== "stop"

  readonly property var idleOptions: [
    { "value": "1", "label": "1m" },
    { "value": "5", "label": "5m" },
    { "value": "15", "label": "15m" },
    { "value": "60", "label": "1h" },
    { "value": "0", "label": "Never" }
  ]

  // --- keyboard cursor --------------------------------------------------------
  // One flat list of the things that can be activated, top to bottom.
  readonly property var rows: {
    var list = []
    if (!installed) return [{ "kind": "install" }]
    list.push({ "kind": "power" })
    if (confirmStop) {
      list.push({ "kind": "stopNow" })
      list.push({ "kind": "stopCancel" })
    }
    for (var i = 0; i < apps.length; i++) list.push({ "kind": "app", "index": i })
    list.push({ "kind": "desktop" })
    list.push({ "kind": "manage" })
    list.push({ "kind": "resources" })
    list.push({ "kind": "idle" })
    return list
  }
  property int cursor: 0
  property bool cursorActive: false
  property int idleCursor: 0

  function cursorOn(kind, index) {
    if (!cursorActive || cursor < 0 || cursor >= rows.length) return false
    var row = rows[cursor]
    return row.kind === kind && (index === undefined || row.index === index)
  }

  function setCursor(kind, index) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === kind && (index === undefined || rows[i].index === index)) {
        cursorActive = true
        cursor = i
        return
      }
    }
  }

  function moveCursor(dx, dy) {
    if (!cursorActive) { cursorActive = true; return }
    if (dy !== 0) {
      cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
      if (cursorOn("idle")) idleCursor = selectedIdleIndex()
      scrollCursorIntoView()
    } else if (dx !== 0 && cursorOn("idle")) {
      idleCursor = Math.max(0, Math.min(idleOptions.length - 1, idleCursor + dx))
    }
  }

  function activateCursor() {
    if (!cursorActive || cursor < 0 || cursor >= rows.length) return
    var row = rows[cursor]
    if (row.kind === "power") togglePower()
    else if (row.kind === "stopNow") stopVm()
    else if (row.kind === "stopCancel") confirmStop = false
    else if (row.kind === "app") launch(apps[row.index].id)
    else if (row.kind === "desktop") openDesktop()
    else if (row.kind === "manage") manageApps()
    else if (row.kind === "resources") changeResources()
    else if (row.kind === "idle") setIdle(idleOptions[idleCursor].value)
    else if (row.kind === "install") installVm()
  }

  function selectedIdleIndex() {
    for (var i = 0; i < idleOptions.length; i++) if (idleOptions[i].value === String(idleMinutes)) return i
    return 0
  }

  function scrollCursorIntoView() {
    if (!panelFlick || cursor < 0 || cursor >= rows.length || rows[cursor].kind !== "app") return
    var item = appColumn.children[rows[cursor].index]
    if (!item) return
    Qt.callLater(function() {
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  onRowsChanged: if (cursor >= rows.length) cursor = Math.max(0, rows.length - 1)

  // --- talking to winapp ------------------------------------------------------
  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function applyState(text) {
    var parsed
    try { parsed = JSON.parse(text) } catch (e) { parsed = null }
    if (!parsed || !parsed.vm) {
      lastError = "The winapp command did not answer. Run the plugin's setup script."
      return
    }
    lastError = ""
    installed = parsed.installed !== false
    vm = parsed.vm
    windows = parsed.windows || 0
    desktop = parsed.desktop === true
    ram = String(parsed.ram || "")
    cores = String(parsed.cores || "")
    idleMinutes = parsed.idleMinutes
    idleDeadline = parsed.idleDeadline || 0
    clockOffset = (parsed.now || 0) - Date.now() / 1000
    // reassign only on change, or every poll would rebuild the rows
    if (JSON.stringify(parsed.apps || []) !== JSON.stringify(apps)) apps = parsed.apps || []
    if (pending === "start" && vm !== "stopped") pending = ""
    if (pending === "stop" && vm !== "running") pending = ""
    if (vm !== "running" || windows === 0) confirmStop = false
    tick()
  }

  function tick() {
    if (idleDeadline <= 0) { idleLeft = 0; return }
    idleLeft = Math.max(0, Math.round(idleDeadline - (Date.now() / 1000 + clockOffset)))
  }

  function countdown() {
    var m = Math.floor(idleLeft / 60)
    var s = idleLeft % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  function statusText() {
    if (lastError !== "") return "Not working"
    if (!installed) return "Not set up"
    if (vm === "stopping" || pending === "stop") return "Shutting down…"
    if (off) return "Off"
    if (vm !== "running") return "Starting…"
    if (desktop) return "Desktop open"
    if (windows > 0) return windows + (windows === 1 ? " window open" : " windows open")
    if (idleDeadline > 0) return "Idle · stops in " + countdown()
    if (idleMinutes === 0) return "On · stays on until stopped"
    return "On"
  }

  function run(args) {
    Quickshell.execDetached([win.command].concat(args))
    refreshSoon.restart()
  }

  function inTerminal(script) {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", script])
    win.close()
  }

  function shellQuote(text) {
    return "'" + String(text).replace(/'/g, "'\\''") + "'"
  }

  function expectStart() {
    if (vm !== "stopped") return
    pending = "start"
    pendingTimeout.restart()
  }

  function launch(app) {
    expectStart()
    run([app])
    win.close()
  }

  function openDesktop() {
    expectStart()
    run(["desktop"])
    win.close()
  }

  function manageApps() { inTerminal(shellQuote(win.command) + " manage") }
  function changeResources() { inTerminal(shellQuote(win.command) + " resources --pick") }

  function resourcesText() {
    if (ram === "" || cores === "") return "How much of this computer Windows gets"
    return ram.replace(/G$/, " GB") + " · " + cores + (cores === "1" ? " processor" : " processors")
  }
  function installVm() { inTerminal("omarchy-windows-vm install && " + shellQuote(win.command) + " setup") }

  function startVm() {
    expectStart()
    run(["start"])
  }

  function stopVm() {
    confirmStop = false
    pending = "stop"
    pendingTimeout.restart()
    run(["stop"])
  }

  // Stopping with apps open would take unsaved work with it: ask first, in
  // the panel, which a keybinding may have to open for the question to be seen.
  function togglePower() {
    if (busy) return
    if (off) startVm()
    else if (windows > 0 && !confirmStop) {
      if (!opened) open()
      confirmStop = true
      setCursor("stopCancel")
    }
    else stopVm()
  }

  function setIdle(minutes) {
    idleMinutes = parseInt(minutes)
    run(["idle", String(minutes)])
  }

  visible: !hideWhenStopped || !off || opened
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) { confirmStop = false; return }
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: stateProc
    command: [win.command, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: win.applyState(text)
    }
    onExited: function(code) { if (code !== 0) win.applyState("") }
  }

  // Slow while nothing is running, quicker once there is something to show.
  Timer {
    interval: win.opened || win.busy ? 2000 : (win.vm === "stopped" ? 8000 : 3000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: win.refresh()
  }

  Timer {
    interval: 1000
    running: win.opened && win.idleDeadline > 0
    repeat: true
    onTriggered: win.tick()
  }

  Timer {
    id: refreshSoon
    interval: 600
    onTriggered: win.refresh()
  }

  // A start or stop the helper never confirmed (a dismissed password prompt,
  // say) must not leave the panel claiming it is still under way.
  Timer {
    id: pendingTimeout
    interval: 20000
    onTriggered: win.pending = ""
  }

  IpcHandler {
    target: win.ipcTarget
    function open(): void { win.open() }
    function close(): void { win.close() }
    function show(): void { win.open() }
    function hide(): void { win.close() }
    function toggle(): void { win.toggle() }
    function refresh(): string { win.refresh(); return "ok" }
    function start(): string { win.startVm(); return "ok" }
    function stop(): string { win.stopVm(); return "ok" }
    function power(): string { win.togglePower(); return win.statusText() }
    function status(): string { return win.statusText() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: win.bar
    text: win.glyphWindows
    opacity: win.off ? 0.4 : (win.busy ? 0.7 : 1.0)
    tooltipText: "Windows · " + win.statusText()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) win.refresh()
      else win.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: win
    bar: win.bar
    open: win.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { win.moveCursor(dx, dy) }
      onActivateRequested: win.activateCursor()
      onCloseRequested: {
        if (win.confirmStop) win.confirmStop = false
        else win.close()
      }
      onTabRequested: function(direction) { win.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") win.refresh()
        else if (t === "d" || t === "D") win.openDesktop()
        else if (t === "a" || t === "A") win.manageApps()
        else if (t === "m" || t === "M") win.changeResources()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // The hero's trailing control is created inside PanelHero, so it
            // reads panel state through this item rather than by id.
            readonly property bool ringVisible: win.cursorOn("power")
            readonly property bool switchVisible: win.installed && win.lastError === ""
            readonly property bool switchOn: win.on
            readonly property bool switchBusy: win.busy
            readonly property string hint: win.off ? "Start Windows" : "Stop Windows"
            function focusSwitch() { win.setCursor("power") }
            function toggle() { win.togglePower() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Windows"
              meta: win.statusText()
              foreground: win.foreground
              fontFamily: win.fontFamily
              iconOpacity: win.off ? 0.5 : 1.0
              iconComponent: Component {
                Text {
                  text: win.glyphWindows
                  color: win.foreground
                  font.family: win.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: header.switchVisible
                  checked: header.switchOn
                  busy: header.switchBusy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(isHovered) { if (isHovered) header.focusSwitch() }
                  onToggled: header.toggle()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: header.hint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: win.lastError !== ""
            width: parent.width
            text: win.lastError
            color: win.urgent
            font.family: win.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Stopping while apps are open
          Column {
            visible: win.confirmStop
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: (win.windows === 1 ? "A Windows app is" : win.windows + " Windows app windows are")
                + " still open. Stopping now discards anything not saved."
              color: win.urgent
              font.family: win.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Stop anyway"
                fontSize: Style.font.caption
                foreground: win.foreground
                fontFamily: win.fontFamily
                bordered: true
                hasCursor: win.cursorOn("stopNow")
                onHovered: function(isHovered) { if (isHovered) win.setCursor("stopNow") }
                onClicked: win.stopVm()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Keep running"
                fontSize: Style.font.caption
                foreground: win.foreground
                fontFamily: win.fontFamily
                bordered: true
                hasCursor: win.cursorOn("stopCancel")
                onHovered: function(isHovered) { if (isHovered) win.setCursor("stopCancel") }
                onClicked: win.confirmStop = false
              }
            }
          }

          // No VM yet
          Column {
            visible: !win.installed
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Omarchy can run Windows in a virtual machine. Once it is installed, its apps open here as ordinary windows, on your Linux files."
              color: win.dim
              font.family: win.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            ActionRow {
              width: parent.width
              kind: "install"
              glyph: win.glyphInstall
              title: "Install the Windows VM"
              subtitle: "Downloads Windows 11, about 15 minutes"
              onActivated: win.installVm()
            }
          }

          PanelSeparator {
            visible: win.installed
            foreground: win.foreground
          }

          Column {
            visible: win.installed
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "APPS"
              foreground: win.foreground
              fontFamily: win.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: win.apps.length === 0
              width: parent.width
              text: "No apps yet. Choose from what is installed in Windows below."
              color: win.dim
              font.family: win.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              id: appColumn
              visible: win.apps.length > 0
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: win.apps

                AppRow {
                  required property var modelData
                  required property int index
                  width: appColumn.width
                  app: modelData
                  rowIndex: index
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              ActionRow {
                width: parent.width
                kind: "desktop"
                glyph: win.glyphDesktop
                title: "Windows desktop"
                subtitle: win.desktop ? "Open now; close it to use single apps" : "Install programs, change settings"
                onActivated: win.openDesktop()
              }

              ActionRow {
                width: parent.width
                kind: "manage"
                glyph: win.glyphApps
                title: "Add or remove apps"
                subtitle: "Pick from what is installed in Windows"
                onActivated: win.manageApps()
              }

              ActionRow {
                width: parent.width
                kind: "resources"
                glyph: win.glyphChip
                title: "Memory and processors"
                subtitle: win.resourcesText()
                onActivated: win.changeResources()
              }
            }
          }

          PanelSeparator {
            visible: win.installed
            foreground: win.foreground
          }

          Column {
            visible: win.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "STOP WHEN IDLE FOR"
              foreground: win.foreground
              fontFamily: win.fontFamily
            }

            ButtonGroup {
              options: win.idleOptions
              value: String(win.idleMinutes)
              cursorIndex: win.cursorOn("idle") ? win.idleCursor : -1
              foreground: win.foreground
              fontFamily: win.fontFamily
              fontSize: Style.font.caption
              focusable: false
              spacing: Style.spacing.xs
              onChanged: function(value) { win.setIdle(value) }
              onHovered: function(index, isHovered) {
                if (!isHovered) return
                win.setCursor("idle")
                win.idleCursor = index
              }
            }
          }
        }
      }
    }
  }

  // One app: its own icon, fetched from Windows, and its name.
  component AppRow: CursorSurface {
    id: appRow
    property var app: null
    property int rowIndex: 0
    readonly property string iconPath: app && app.icon ? String(app.icon) : ""

    hasCursor: win.cursorOn("app", rowIndex)
    foreground: win.foreground
    implicitHeight: Math.max(appIcon.height, appName.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: win.setCursor("app", appRow.rowIndex)
      onClicked: win.launch(appRow.app.id)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Item {
        id: appIcon
        width: Style.space(20)
        height: Style.space(20)
        Layout.alignment: Qt.AlignVCenter

        Image {
          id: appImage
          anchors.fill: parent
          visible: status === Image.Ready
          source: appRow.iconPath.indexOf("/") === 0 ? "file://" + appRow.iconPath : ""
          sourceSize.width: 64
          sourceSize.height: 64
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          mipmap: true
        }

        Text {
          anchors.centerIn: parent
          visible: !appImage.visible
          text: win.glyphWindows
          color: win.dim
          font.family: win.fontFamily
          font.pixelSize: Style.font.icon
        }
      }

      Text {
        id: appName
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: appRow.app ? String(appRow.app.name || appRow.app.id) : ""
        color: win.foreground
        font.family: win.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }
  }

  // A row that does something other than open an app.
  component ActionRow: CursorSurface {
    id: actionRow
    property string kind: ""
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    signal activated()

    hasCursor: win.cursorOn(kind)
    foreground: win.foreground
    implicitHeight: actionText.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: win.setCursor(actionRow.kind)
      onClicked: actionRow.activated()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        text: actionRow.glyph
        color: win.foreground
        font.family: win.fontFamily
        font.pixelSize: Style.font.icon
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Style.space(20)
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: actionText
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.title
          color: win.foreground
          font.family: win.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.subtitle
          color: win.dim
          font.family: win.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
