import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for the Windows VM behind the bundled `winapp` command. The icon
// is dim while Windows is off or asleep; the panel opens Windows apps in the
// Windows window (starting or waking the VM first when needed), turns Windows
// on, puts it to sleep (paused, still in memory) or shuts it down (memory
// freed), and sets how long it sits idle before it sleeps. Everything it shows
// comes from `winapp state`, and everything it does is a `winapp` command.
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
  readonly property string glyphFolder: String.fromCodePoint(0xF024B)
  readonly property string glyphTune: String.fromCodePoint(0xF062E)
  readonly property string glyphOn: String.fromCodePoint(0xF0425)
  readonly property string glyphSleep: String.fromCodePoint(0xF04B2)
  readonly property string glyphOff: String.fromCodePoint(0xF06A6)

  // --- state, as reported by `winapp state` -----------------------------------
  property bool installed: true
  property string vm: "stopped"        // stopped | starting | running | asleep | stopping
  property int windows: 0
  property bool desktop: false         // the full desktop is open; apps cannot be
  property bool canSleep: true         // false without direct Docker: the idle timer shuts down
  property int idleMinutes: 5
  property real idleDeadline: 0        // epoch seconds, 0 = no countdown
  property real clockOffset: 0         // helper clock minus ours, in seconds
  property int idleLeft: 0
  property var apps: []
  property string ram: ""              // "16G", empty when not known
  property string cores: ""
  property var shares: []              // names of the folders shared with Windows
  property int undecided: 0            // changes to Windows waiting for an answer
  property string lastError: ""
  // What was just asked for, until the helper's own state catches up.
  property string pending: ""          // "" | "start" | "sleep" | "stop"
  property bool confirmStop: false

  readonly property bool off: vm === "stopped" && pending !== "start"
  readonly property bool asleep: vm === "asleep" && pending === ""
  readonly property bool busy: vm === "starting" || vm === "stopping" || pending !== ""
  readonly property bool awake: vm === "running" && pending === ""

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
    if (off || asleep) list.push({ "kind": "on" })
    if (awake && canSleep) list.push({ "kind": "sleep" })
    if (awake || asleep) list.push({ "kind": "shutdown" })
    if (confirmStop) {
      list.push({ "kind": "stopNow" })
      list.push({ "kind": "stopCancel" })
    }
    for (var i = 0; i < apps.length; i++) list.push({ "kind": "app", "index": i })
    list.push({ "kind": "desktop" })
    list.push({ "kind": "manage" })
    list.push({ "kind": "resources" })
    list.push({ "kind": "shares" })
    if (undecided > 0) list.push({ "kind": "changes" })
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
    if (row.kind === "on") turnOn()
    else if (row.kind === "sleep") sleepVm()
    else if (row.kind === "shutdown") askShutDown()
    else if (row.kind === "stopNow") stopVm()
    else if (row.kind === "stopCancel") confirmStop = false
    else if (row.kind === "app") launch(apps[row.index].id)
    else if (row.kind === "desktop") openDesktop()
    else if (row.kind === "manage") manageApps()
    else if (row.kind === "resources") changeResources()
    else if (row.kind === "shares") pickShares()
    else if (row.kind === "changes") reviewChanges()
    else if (row.kind === "idle") setIdle(idleOptions[idleCursor].value)
    else if (row.kind === "install") installVm()
  }

  function selectedIdleIndex() {
    for (var i = 0; i < idleOptions.length; i++) if (idleOptions[i].value === String(idleMinutes)) return i
    return 0
  }

  function scrollCursorIntoView() {
    if (!panelFlick || cursor < 0 || cursor >= rows.length) return
    if (rows[cursor].kind === "idle") {
      // the last section: all the way down shows it whole
      Qt.callLater(function() { panelFlick.contentY = Math.max(0, panelFlick.contentHeight - panelFlick.height) })
      return
    }
    if (rows[cursor].kind !== "app") return
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
    if (JSON.stringify(parsed.shares || []) !== JSON.stringify(shares)) shares = parsed.shares || []
    undecided = parsed.undecided || 0
    canSleep = parsed.canSleep !== false
    idleMinutes = parsed.idleMinutes
    idleDeadline = parsed.idleDeadline || 0
    clockOffset = (parsed.now || 0) - Date.now() / 1000
    // reassign only on change, or every poll would rebuild the rows
    if (JSON.stringify(parsed.apps || []) !== JSON.stringify(apps)) apps = parsed.apps || []
    if (pending === "start" && vm !== "stopped" && vm !== "asleep") pending = ""
    if (pending === "sleep" && vm !== "running") pending = ""
    if (pending === "stop" && vm !== "running" && vm !== "asleep") pending = ""
    if (vm !== "running" && vm !== "asleep") confirmStop = false
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
    if (pending === "sleep") return "Going to sleep…"
    if (off) return "Off"
    if (vm === "asleep" && pending === "start") return "Waking…"
    if (asleep) return "Asleep"
    if (vm !== "running") return "Starting…"
    if (desktop) return "Open"
    if (idleDeadline > 0) return "Idle · " + (canSleep ? "sleeps" : "shuts down") + " in " + countdown()
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
    if (vm !== "stopped" && vm !== "asleep") return
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
  function pickShares() { inTerminal(shellQuote(win.command) + " share pick") }
  function reviewChanges() { inTerminal(shellQuote(win.command) + " changes") }

  function sharesText() {
    if (shares.length === 0) return "None: only the folder of each file you open"
    return shares.join(", ")
  }
  function changesText() {
    return undecided + (undecided === 1 ? " question" : " questions") + " waiting for your answer"
  }

  function resourcesText() {
    if (ram === "" || cores === "") return "How much of this computer Windows gets"
    return ram.replace(/G$/, " GB") + " · " + cores + (cores === "1" ? " processor" : " processors")
  }
  function installVm() { inTerminal("omarchy-windows-vm install && " + shellQuote(win.command) + " setup") }

  function startVm() {
    expectStart()
    run(["start"])
  }

  // On: start or wake Windows, and open its window.
  function turnOn() {
    if (busy) return
    openDesktop()
  }

  function sleepVm() {
    if (busy || !awake || !canSleep) return
    confirmStop = false
    pending = "sleep"
    pendingTimeout.restart()
    run(["sleep"])
  }

  function stopVm() {
    confirmStop = false
    pending = "stop"
    pendingTimeout.restart()
    run(["stop"])
  }

  // Apps in Windows keep running when its window is closed, and asleep they
  // are as they were left, so shutting down could take unsaved work with it:
  // ask first, in the panel, which a keybinding may have to open for the
  // question to be seen.
  function askShutDown() {
    if (busy || !(awake || asleep)) return
    if (!opened) open()
    confirmStop = true
    setCursor("stopCancel")
  }

  // The bar's power key: on when off or asleep, otherwise sleep (or, where
  // Windows cannot sleep, the shut-down question).
  function togglePower() {
    if (busy) return
    if (off || asleep) turnOn()
    else if (canSleep) sleepVm()
    else if (!confirmStop) askShutDown()
    else stopVm()
  }

  function memoryText() {
    return ram !== "" ? ram.replace(/G$/, " GB") : "its memory"
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
    function sleep(): string { win.sleepVm(); return "ok" }
    function power(): string { win.togglePower(); return win.statusText() }
    function status(): string { return win.statusText() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: win.bar
    text: win.glyphWindows
    opacity: win.off || win.asleep ? 0.4 : (win.busy ? 0.7 : 1.0)
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

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

          PanelHero {
            id: hero
            width: parent.width
            title: "Windows"
            meta: win.statusText()
            foreground: win.foreground
            fontFamily: win.fontFamily
            iconOpacity: win.off || win.asleep ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                text: win.glyphWindows
                color: win.foreground
                font.family: win.fontFamily
                font.pixelSize: Style.font.display
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

          // On, sleep, shut down: only what makes sense from where it is
          Column {
            visible: win.installed && win.lastError === ""
            width: parent.width
            spacing: Style.space(2)

            ActionRow {
              visible: win.off || win.asleep || (win.busy && win.pending === "start")
              width: parent.width
              kind: "on"
              glyph: win.glyphOn
              title: "On"
              subtitle: win.vm === "asleep" ? "Wakes Windows as you left it" : "Starts Windows and opens it"
              onActivated: win.turnOn()
            }

            ActionRow {
              visible: win.canSleep && (win.awake || win.pending === "sleep")
              width: parent.width
              kind: "sleep"
              glyph: win.glyphSleep
              title: "Sleep"
              subtitle: "Keeps Windows in RAM (" + win.memoryText() + ")"
              onActivated: win.sleepVm()
            }

            ActionRow {
              visible: win.awake || win.asleep || win.pending === "stop" || win.vm === "stopping"
              width: parent.width
              kind: "shutdown"
              glyph: win.glyphOff
              title: "Shut down"
              subtitle: "Frees the RAM (" + win.memoryText() + ")"
              onActivated: win.askShutDown()
            }
          }

          // Shutting down while apps may be open
          Column {
            visible: win.confirmStop
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Apps in Windows keep running when its window is closed, and asleep they stay as they were."
                + " Shutting down discards anything not saved in them."
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
                text: "Shut down"
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
                text: "Cancel"
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
              text: "Omarchy can run Windows in a virtual machine. Once it is installed, Windows opens here in a window, and your Linux files open in its apps."
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
                title: "Windows"
                subtitle: win.desktop ? "Open: bring it forward" : "The desktop, where apps and files open"
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

              ActionRow {
                width: parent.width
                kind: "shares"
                glyph: win.glyphFolder
                title: "Shared folders"
                subtitle: win.sharesText()
                onActivated: win.pickShares()
              }

              // Only while a question is open: the panel is as tall as it
              // can be, and `winapp changes` is there for a change of mind.
              ActionRow {
                visible: win.undecided > 0
                width: parent.width
                kind: "changes"
                glyph: win.glyphTune
                title: "Changes to Windows"
                subtitle: win.changesText()
                onActivated: win.reviewChanges()
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
              text: win.canSleep ? "SLEEP WHEN IDLE FOR" : "SHUT DOWN WHEN IDLE FOR"
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
