import QtQuick
import QtQuick.Controls
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// UniFi Protect popup.
//
// Two views share the card: a grid of camera snapshots, and a live view of
// one camera. The panel never speaks HTTP. `eld-unifi-protect` polls the
// console, writes state and snapshots to disk, and resolves stream URLs; the
// panel watches those files and plays the RTSPS stream with QtMultimedia.
//
// Snapshots only refresh while the panel is open, and live video only plays
// while it is shown: a closed panel costs the console one camera-list poll a
// minute, for the bar's health colour.
Panel {
  id: root
  moduleName: "com.eldtechnologies.unifi-protect"
  manageIpc: false

  property Item anchorItem: null
  property var hostWidget: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state")
  readonly property string statePath: stateHome + "/eld-unifi-protect/state.json"
  // No shared fallback such as /tmp: the helper refuses to run without the
  // private runtime directory, so there would be nothing to read there.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
                                       ? Quickshell.env("XDG_RUNTIME_DIR") + "/eld-unifi-protect" : ""
  readonly property string snapDir: runtimeDir + "/snapshots"
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace("file://", ""))
  readonly property string cli: pluginDir + "bin/eld-unifi-protect"

  readonly property int snapshotSeconds: Math.max(1, setting("snapshotIntervalSec", 3))
  readonly property int columns: Math.max(1, Math.min(4, setting("columns", 2)))
  readonly property string liveQuality: validQuality(setting("liveQuality", "medium"), "medium")
  readonly property string popoutQuality: validQuality(setting("popoutQuality", "high"), "high")

  property var state: ({})
  property var snapIndex: ({})

  // ---- derived state -------------------------------------------------

  readonly property var allCameras: state && state.cameras ? state.cameras : []
  // Hidden cameras (by hand, or offline with hideOffline on) leave the grid,
  // the keyboard order and the bar's health colour alike; "Show hidden"
  // brings them back to the grid only, so they can be unhidden.
  readonly property bool hideOffline: state && state.hideOffline === true
  property bool showHidden: false
  function isHidden(camera) { return camera.hidden === true || (hideOffline && !camera.online) }
  readonly property var shownCameras: allCameras.filter(function(c) { return !root.isHidden(c) })
  readonly property var cameras: showHidden ? allCameras : shownCameras
  readonly property int hiddenCount: allCameras.length - shownCameras.length
  readonly property var consoles: state && state.consoles ? state.consoles : []
  readonly property bool multiConsole: consoles.length > 1
  readonly property bool configured: state && state.updatedAt !== undefined
                                     && state.configured !== false
  readonly property bool stale: configured && state.stale === true
  readonly property int onlineCount: {
    var count = 0
    for (var i = 0; i < shownCameras.length; i++) if (shownCameras[i].online) count++
    return count
  }
  readonly property bool healthy: configured && onlineCount === shownCameras.length

  readonly property string barTooltip: {
    if (!configured) return "UniFi Protect — not set up yet"
    var lines = [onlineCount + "/" + shownCameras.length + " cameras online"
                 + (hiddenCount ? " · " + hiddenCount + " hidden" : "")]
    for (var c = 0; c < consoles.length; c++)
      if (consoles[c].stale) lines.push("! " + consoles[c].name + " unreachable")
    for (var i = 0; i < shownCameras.length; i++)
      if (!shownCameras[i].online) lines.push("! " + shownCameras[i].name + " offline")
    return lines.join("\n")
  }

  // ---- live view state -----------------------------------------------

  property var liveCamera: null
  property string liveError: ""
  property bool muted: true
  property int selectedIndex: 0

  readonly property bool liveMode: liveCamera !== null
  readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
                                  && player.mediaStatus !== MediaPlayer.LoadingMedia
                                  && player.mediaStatus !== MediaPlayer.StalledMedia

  function validQuality(value, fallback) {
    return ["high", "medium", "low"].indexOf(String(value)) >= 0 ? String(value) : fallback
  }

  function snapshotUrl(cameraId) {
    var stamp = root.snapIndex[cameraId]
    if (!stamp) return ""
    // The query only defeats the pixmap cache; the loader ignores it.
    return "file://" + root.snapDir + "/" + cameraId + ".jpg?t=" + stamp
  }

  function openLive(camera) {
    if (!camera) return
    root.liveError = ""
    root.liveCamera = camera
    for (var i = 0; i < cameras.length; i++) if (cameras[i].uid === camera.uid) root.selectedIndex = i
    player.stop()
    player.source = ""
    if (!camera.online) {
      root.liveError = camera.name + " is offline"
      return
    }
    // Always ask the CLI: it caches Protect's URLs, and it makes sure the
    // encrypted relay the URL points at is actually running.
    var key = camera.uid + ":" + root.liveQuality
    if (streamProcess.running) streamProcess.running = false
    streamProcess.cameraKey = key
    streamProcess.command = [root.cli, "stream", camera.uid, "--quality", root.liveQuality]
    streamProcess.running = true
  }

  function openLiveByName(name) {
    var wanted = String(name || "").toLowerCase()
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].name.toLowerCase() === wanted || cameras[i].uid === name || cameras[i].id === name) {
        root.open()
        root.openLive(cameras[i])
        return
      }
    }
    root.open()
  }

  function stepLive(delta) {
    if (cameras.length === 0) return
    var next = (root.selectedIndex + delta + cameras.length) % cameras.length
    root.openLive(cameras[next])
  }

  function closeLive() {
    player.stop()
    player.source = ""
    streamProcess.running = false
    root.liveCamera = null
    root.liveError = ""
  }

  function popOut(camera) {
    if (!camera) return
    Quickshell.execDetached([root.cli, "live", camera.uid,
                             "--quality", root.popoutQuality, "--title", camera.name])
    root.closeLive()
    root.close()
  }

  function moveSelection(dx, dy) {
    if (cameras.length === 0) return
    var next = root.selectedIndex + dx + dy * root.columns
    root.selectedIndex = Math.max(0, Math.min(cameras.length - 1, next))
  }

  // ---- state and actions ---------------------------------------------

  function applyState(text) {
    if (!text || text.trim() === "") return
    try { root.state = JSON.parse(text) } catch (error) { }
  }

  function applyIndex(text) {
    if (!text || text.trim() === "") return
    try { root.snapIndex = JSON.parse(text) } catch (error) { }
  }

  function reloadState() {
    if (pollProcess.running) return
    pollProcess.running = true
  }

  // Opens the console that hosts the selected camera, so right-click lands
  // on the right Protect when there are several.
  function openConsole() {
    var camera = cameras[root.selectedIndex]
    var args = [root.cli, "open"]
    if (camera && camera.console) args.push(camera.console)
    Quickshell.execDetached(args)
  }

  function hideCamera(camera, hide) {
    Quickshell.execDetached([root.cli, hide ? "hide" : "unhide", camera.uid])
  }

  function toggleHideOffline() {
    Quickshell.execDetached([root.cli, "hide-offline", "toggle"])
  }

  function openWall() {
    Quickshell.execDetached([root.cli, "wall"])
    root.close()
  }

  // ---- setup, inside the panel ----
  //
  // Two steps, each a call to the helper: setup-probe fetches the console's
  // certificate fingerprint for the user to trust, then setup-save checks
  // the API key against that pinned certificate and stores it. The key is
  // handed to the helper on stdin, never as an argument, and the field is
  // cleared as soon as it is sent, the same way Omarchy's own network panel
  // handles Wi-Fi passwords.
  property string setupStep: ""          // "", "address", "key"
  property string setupHost: ""
  property string setupPin: ""
  property bool setupPinChanged: false
  property bool setupExisting: false
  property string setupSuggestedName: ""
  property string setupError: ""
  property string setupBusy: ""
  property string setupDone: ""
  readonly property bool settingUp: setupStep !== ""

  function openSetup() {
    root.closeLive()
    root.setupError = ""
    root.setupBusy = ""
    root.setupStep = "address"
    Qt.callLater(function() { if (addressField) addressField.forceActiveFocus() })
  }

  function addConsole() { root.openSetup() }

  function cancelSetup() {
    setupProbe.running = false
    keyField.text = ""
    root.setupStep = ""
    root.setupError = ""
    root.setupBusy = ""
    keyCatcher.forceActiveFocus()
  }

  function setupInTerminal() {
    Quickshell.execDetached(["xdg-terminal-exec", root.cli, "setup"])
    root.cancelSetup()
    root.close()
  }

  function probeConsole() {
    var host = addressField.text.trim()
    if (host === "" || setupProbe.running) return
    root.setupError = ""
    root.setupBusy = "Reaching " + host + "…"
    setupProbe.command = [root.cli, "setup-probe", host]
    setupProbe.running = true
  }

  function connectConsole() {
    if (setupSave.running) return
    if (keyField.text.trim() === "" && !root.setupExisting) {
      root.setupError = "Paste the API key"
      return
    }
    root.setupError = ""
    root.setupBusy = "Checking the key with " + root.setupHost + "…"
    setupSave.secret = keyField.text.trim()
    keyField.text = ""
    setupSave.command = [root.cli, "setup-save", "--host", root.setupHost,
                         "--pin", root.setupPin, "--name", nameField.text.trim()]
    setupSave.running = true
  }

  function helperError(text, fallback) {
    var message = text.trim().replace(/^eld-unifi-protect: /, "")
    return message !== "" ? message : fallback
  }

  Process {
    id: setupProbe
    running: false
    stdout: StdioCollector { id: probeOut }
    stderr: StdioCollector { id: probeErr }
    onExited: function(exitCode) {
      root.setupBusy = ""
      if (exitCode !== 0) {
        root.setupError = root.helperError(probeErr.text, "Could not reach the console")
        return
      }
      try {
        var result = JSON.parse(probeOut.text)
        root.setupHost = result.host
        root.setupPin = result.fingerprint
        root.setupPinChanged = result.changed === true
        root.setupExisting = result.existing === true
        root.setupSuggestedName = result.suggestedName || "Console"
        nameField.text = root.setupSuggestedName
        root.setupStep = "key"
        Qt.callLater(function() { keyField.forceActiveFocus() })
      } catch (error) {
        root.setupError = "Unexpected answer from the helper"
      }
    }
  }

  Process {
    id: setupSave
    property string secret: ""
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: saveOut }
    stderr: StdioCollector { id: saveErr }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      root.setupBusy = ""
      if (exitCode !== 0) {
        root.setupError = root.helperError(saveErr.text, "Could not save the console")
        Qt.callLater(function() { keyField.forceActiveFocus() })
        return
      }
      try {
        var result = JSON.parse(saveOut.text)
        root.setupDone = "Connected to " + result.name + " · " + result.online + "/"
          + result.cameras + " cameras online · key stored in "
          + (result.keyStore === "keyring" ? "your keyring" : "your config file")
      } catch (error) {
        root.setupDone = "Console connected"
      }
      setupDoneTimer.restart()
      root.cancelSetup()
      root.reloadState()
    }
  }

  Timer {
    id: setupDoneTimer
    interval: 8000
    onTriggered: root.setupDone = ""
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    onLoadFailed: root.state = ({})
  }

  FileView {
    id: indexFile
    path: root.snapDir + "/index.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyIndex(text())
  }

  Component.onCompleted: reloadState()

  onOpenedChanged: {
    if (opened) {
      root.reloadState()
      indexFile.reload()
      if (root.selectedIndex >= cameras.length) root.selectedIndex = 0
    } else {
      root.closeLive()
      root.showHidden = false
      if (root.settingUp) root.cancelSetup()
    }
  }

  Process {
    id: pollProcess
    running: false
    command: [root.cli, "poll"]
    onExited: stateFile.reload()
  }

  // Background poll for the bar's health colour while the panel is closed.
  Timer {
    interval: 60000
    repeat: true
    running: !root.opened
    onTriggered: root.reloadState()
  }

  // Snapshot loop, alive only while the panel is open on the grid. In live
  // view the stream replaces it, so the console is not serving both.
  Process {
    id: watchProcess
    running: root.opened && root.configured && !root.liveMode
    command: [root.cli, "watch", "--interval", String(root.snapshotSeconds)]
  }

  Process {
    id: streamProcess
    property string cameraKey: ""
    running: false
    stdout: StdioCollector { id: streamOut }
    stderr: StdioCollector { id: streamErr }
    onExited: function(exitCode) {
      if (!root.liveMode) return
      if (exitCode !== 0) {
        root.liveError = streamErr.text.trim().replace(/^eld-unifi-protect: /, "")
                         || "could not open the stream"
        return
      }
      var url = streamOut.text.trim()
      // Ignore a late answer for a camera the user has already left.
      if (cameraKey !== root.liveCamera.uid + ":" + root.liveQuality) return
      player.source = url
      player.play()
    }
  }

  MediaPlayer {
    id: player
    videoOutput: videoOutput
    audioOutput: AudioOutput { muted: root.muted }
    playbackOptions.playbackIntent: PlaybackOptions.PlaybackIntent.LowLatencyStreaming
    playbackOptions.networkTimeoutMs: 8000
    onErrorOccurred: function(error, errorString) {
      if (root.liveMode) root.liveError = errorString || "playback failed"
    }
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color surface: Util.alpha(foreground, 0.05)

  component ActionButton: Button {
    property string label: ""
    property bool outlined: false
    signal triggered()

    text: label
    bordered: outlined
    foreground: root.foreground
    accent: Color.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    opacity: enabled ? 1 : 0.4
    onClicked: if (enabled) triggered()
  }

  // Two images, swapped once the new frame has decoded, so a refresh never
  // flashes an empty tile between snapshots.
  component Snapshot: Item {
    id: snap
    property string url: ""
    property int front: 0
    clip: true

    onUrlChanged: {
      if (url === "") return
      var back = front === 0 ? imageB : imageA
      back.source = url
    }

    Image {
      id: imageA
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: 960
      visible: snap.front === 0
      onStatusChanged: if (status === Image.Ready && snap.front !== 0) snap.front = 0
    }

    Image {
      id: imageB
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: 960
      visible: snap.front === 1
      onStatusChanged: if (status === Image.Ready && snap.front !== 1) snap.front = 1
    }
  }

  // Lets text stay legible over a bright frame.
  component Scrim: Rectangle {
    gradient: Gradient {
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.7) }
    }
  }

  readonly property int cardWidth: Style.space(root.columns === 1 ? 520 : (root.columns * 340))

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.liveMode ? Math.max(root.cardWidth, Style.space(860))
                                                         : root.cardWidth)
    contentHeight: panel.fittedContentHeight(
      headerRow.implicitHeight + Style.space(10)
        + (root.liveMode ? liveView.implicitHeight
           : root.settingUp ? setupCard.implicitHeight : content.implicitHeight),
      Style.space(1000))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Typing an address or a key must not trigger the panel's letter
      // shortcuts; Esc in a setup field cancels setup instead.
      blocked: root.settingUp

      onCloseRequested: root.liveMode ? root.closeLive() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.liveMode) { if (dx !== 0) root.stepLive(dx) }
        else root.moveSelection(dx, dy)
      }
      onActivateRequested: {
        if (!root.liveMode && root.cameras.length > 0)
          root.openLive(root.cameras[root.selectedIndex])
      }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (key === "m") root.muted = !root.muted
        else if (key === "w") root.openWall()
        else if (key === "p") {
          var target = root.liveMode ? root.liveCamera : root.cameras[root.selectedIndex]
          root.popOut(target)
        }
        else if (key >= "1" && key <= "9" && Number(key) <= root.cameras.length)
          root.openLive(root.cameras[Number(key) - 1])
      }

      Column {
        id: panelBody
        anchors.fill: parent
        spacing: Style.space(10)

        // ---- header ----
        Row {
          id: headerRow
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width - headerActions.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: root.liveMode ? root.liveCamera.name.toUpperCase()
                  + (root.multiConsole ? "  ·  " + root.liveCamera.consoleName.toUpperCase() : "")
                : "UNIFI PROTECT" + (root.configured && root.shownCameras.length
                    ? "  ·  " + root.onlineCount + "/" + root.shownCameras.length + " ONLINE" : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Row {
            id: headerActions
            spacing: Style.space(6)

            ActionButton {
              visible: root.liveMode
              label: root.muted ? "Unmute" : "Mute"
              outlined: true
              onTriggered: root.muted = !root.muted
            }

            ActionButton {
              visible: root.liveMode
              label: "Pop out"
              outlined: true
              onTriggered: root.popOut(root.liveCamera)
            }

            ActionButton {
              visible: root.liveMode
              label: "Back"
              outlined: true
              onTriggered: root.closeLive()
            }

            ActionButton {
              visible: !root.liveMode && !root.settingUp && root.configured && root.shownCameras.length > 0
              label: "Wall"
              outlined: true
              onTriggered: root.openWall()
            }

            ActionButton {
              visible: !root.liveMode && !root.settingUp && root.configured
              label: "Add console"
              outlined: true
              onTriggered: root.addConsole()
            }

            ActionButton {
              visible: !root.liveMode && !root.settingUp && root.configured
              label: "Protect"
              outlined: true
              onTriggered: root.openConsole()
            }
          }
        }

        // ---- live view ----
        Column {
          id: liveView
          visible: root.liveMode
          width: parent.width
          spacing: Style.space(8)

          Rectangle {
            width: parent.width
            height: Math.round(width * 9 / 16)
            radius: Style.cornerRadius
            color: "black"
            clip: true

            // The last snapshot holds the frame while the stream connects.
            Snapshot {
              anchors.fill: parent
              visible: !root.playing
              opacity: 0.6
              url: root.liveMode ? root.snapshotUrl(root.liveCamera.uid) : ""
            }

            VideoOutput {
              id: videoOutput
              anchors.fill: parent
              fillMode: VideoOutput.PreserveAspectFit
            }

            Text {
              anchors.centerIn: parent
              visible: !root.playing
              width: parent.width - Style.space(40)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.liveError !== "" ? root.liveError : "Connecting…"
              color: root.liveError !== "" ? root.urgent : "white"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // LIVE badge: a frozen stream must never pass for a live one.
            Rectangle {
              visible: root.playing
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              width: liveLabel.implicitWidth + Style.space(14)
              height: liveLabel.implicitHeight + Style.space(6)
              radius: height / 2
              color: Qt.rgba(0, 0, 0, 0.55)

              Text {
                id: liveLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "● LIVE"
                color: "#ff5555"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            MouseArea {
              anchors.fill: parent
              onDoubleClicked: root.popOut(root.liveCamera)
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            text: "←/→ switch camera  ·  1–9 jump  ·  M mute  ·  P or double-click pop out  ·  Esc back"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // ---- setup ----
        Column {
          id: setupCard
          visible: root.settingUp
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.configured ? "Add a UniFi Protect console" : "Connect your UniFi Protect console"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          // Step 1: address.
          Text {
            visible: root.setupStep === "address"
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "The console's local address: a Dream Machine, Cloud Gateway, NVR or "
                + "Cloud Key running Protect. Each console needs its own setup."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: addressField
            visible: root.setupStep === "address"
            width: parent.width
            placeholderText: "192.168.1.1"
            text: root.configured ? "" : "192.168.1.1"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onAccepted: root.probeConsole()
            Keys.onEscapePressed: root.cancelSetup()
          }

          // Step 2: trust the certificate, paste the key.
          Text {
            visible: root.setupStep === "key"
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WrapAnywhere
            text: root.setupHost + " presents this certificate (SHA-256):\n" + root.setupPin
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.setupStep === "key" && root.setupPinChanged
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This differs from the certificate trusted before. Continue only if you "
                + "expected it (firmware update, factory reset)."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.setupStep === "key"
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Connecting trusts it: from then on the plugin refuses any other certificate "
                + "from this address, so the key is only ever sent to this console.\n\n"
                + "Create an API key on the console: open https://" + root.setupHost
                + ", click Integrations at the bottom of the left sidebar (older UniFi OS: "
                + "Settings, scroll the tabs sideways), then Create API Key. It is shown once."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: keyField
            visible: root.setupStep === "key"
            width: parent.width
            password: true
            placeholderText: root.setupExisting ? "API key (leave empty to keep the current one)"
                                                : "API key (paste with Super+V)"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onAccepted: root.connectConsole()
            Keys.onEscapePressed: root.cancelSetup()
          }

          TextField {
            id: nameField
            visible: root.setupStep === "key"
            width: parent.width
            placeholderText: "Name, e.g. NVR"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onAccepted: root.connectConsole()
            Keys.onEscapePressed: root.cancelSetup()
          }

          Text {
            visible: root.setupError !== "" || root.setupBusy !== ""
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.setupError !== "" ? root.setupError : root.setupBusy
            color: root.setupError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.space(6)

            ActionButton {
              visible: root.setupStep === "address"
              label: "Next"
              enabled: !setupProbe.running && addressField.text.trim() !== ""
              onTriggered: root.probeConsole()
            }

            ActionButton {
              visible: root.setupStep === "key"
              label: "Connect"
              enabled: !setupSave.running
              onTriggered: root.connectConsole()
            }

            ActionButton {
              label: root.setupStep === "key" ? "Back" : "Cancel"
              outlined: true
              enabled: !setupSave.running
              onTriggered: {
                if (root.setupStep === "key") {
                  keyField.text = ""
                  root.setupError = ""
                  root.setupStep = "address"
                  addressField.text = root.setupHost
                } else {
                  root.cancelSetup()
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Prefer the terminal? Run setup there instead"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: setupTerminalMouse.containsMouse

            MouseArea {
              id: setupTerminalMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setupInTerminal()
            }
          }
        }

        // ---- grid ----
        Flickable {
          id: bodyScroll
          visible: !root.liveMode && !root.settingUp
          width: parent.width
          height: parent.height - headerRow.height - panelBody.spacing
          contentHeight: content.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: content
            width: bodyScroll.width
            spacing: Style.space(10)

            Text {
              visible: root.setupDone !== ""
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.setupDone
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // ---- first-run ----
            Rectangle {
              visible: !root.configured
              width: parent.width
              height: visible ? setupColumn.implicitHeight + Style.space(24) : 0
              radius: Style.cornerRadius
              color: root.surface

              Column {
                id: setupColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(12)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: "Connect your UniFi Protect console"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "Setup asks for your console's address and an API key, and keeps "
                      + "the key in your keyring (or a file only you can read)."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                ActionButton {
                  label: "Run setup"
                  onTriggered: root.openSetup()
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.stale
              width: parent.width
              wrapMode: Text.WordWrap
              text: (root.state.error || "Console unreachable")
                  + " · its cameras show their last snapshot"
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              visible: root.configured && !root.stale && root.cameras.length === 0
                       && root.hiddenCount === 0
              width: parent.width
              text: "No cameras on this console."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Grid {
              id: grid
              visible: root.configured
              width: parent.width
              columns: Math.min(root.columns, Math.max(1, root.cameras.length))
              spacing: Style.space(8)

              readonly property real tileWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: root.configured ? root.cameras : []

                Rectangle {
                  id: tile
                  required property var modelData
                  required property int index
                  readonly property bool selected: index === root.selectedIndex

                  width: grid.tileWidth
                  height: Math.round(width * 9 / 16)
                  radius: Style.cornerRadius
                  color: root.surface
                  clip: true
                  border.width: selected || tileMouse.containsMouse ? Math.max(1, Style.space(2)) : 0
                  border.color: Color.accent

                  readonly property bool hiddenTile: root.isHidden(modelData)

                  Snapshot {
                    anchors.fill: parent
                    anchors.margins: tile.border.width
                    url: root.snapshotUrl(tile.modelData.uid)
                    opacity: (tile.modelData.online ? 1 : 0.3) * (tile.hiddenTile ? 0.4 : 1)
                  }

                  Rectangle {
                    visible: tile.hiddenTile
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.margins: Style.space(8)
                    width: hiddenLabel.implicitWidth + Style.space(12)
                    height: hiddenLabel.implicitHeight + Style.space(4)
                    radius: height / 2
                    color: Qt.rgba(0, 0, 0, 0.6)

                    Text {
                      id: hiddenLabel
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: tile.modelData.hidden ? "HIDDEN" : "HIDDEN · OFFLINE"
                      color: "white"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !tile.modelData.online || !root.snapIndex[tile.modelData.uid]
                    textFormat: Text.PlainText
                    text: tile.modelData.online ? "Loading…" : "Offline"
                    color: tile.modelData.online ? root.dim : root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Scrim {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Style.space(40)
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.right: hideButton.left
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(8)
                    textFormat: Text.PlainText
                    text: (tile.index < 9 ? (tile.index + 1) + "  " : "") + tile.modelData.name
                        + (root.multiConsole ? "  ·  " + tile.modelData.consoleName : "")
                    color: "white"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    id: tileMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selectedIndex = tile.index
                    onClicked: root.openLive(tile.modelData)
                  }

                  PanelActionButton {
                    id: hideButton
                    anchors.right: popButton.visible ? popButton.left : parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(4)
                    // Cameras hidden only for being offline come back via
                    // "Show offline", not one by one.
                    visible: !tile.hiddenTile || tile.modelData.hidden
                    property bool pointerInside: false
                    opacity: tileMouse.containsMouse || pointerInside ? 1 : 0
                    onHovered: function(isHovered) { pointerInside = isHovered }
                    iconText: tile.modelData.hidden ? "\uf06e" : "\uf070"
                    tooltipText: (tile.modelData.hidden ? "Show " : "Hide ") + tile.modelData.name
                    foreground: "white"
                    fontFamily: root.fontFamily
                    onClicked: root.hideCamera(tile.modelData, !tile.modelData.hidden)
                  }

                  PanelActionButton {
                    id: popButton
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(4)
                    visible: tile.modelData.online
                    property bool pointerInside: false
                    opacity: tileMouse.containsMouse || pointerInside ? 1 : 0
                    onHovered: function(isHovered) { pointerInside = isHovered }
                    iconText: ""
                    tooltipText: "Open " + tile.modelData.name + " in a window"
                    foreground: "white"
                    fontFamily: root.fontFamily
                    onClicked: root.popOut(tile.modelData)
                  }
                }
              }
            }

            Row {
              visible: root.configured && root.allCameras.length > 0
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)

              ActionButton {
                label: root.hideOffline ? "Show offline" : "Hide offline"
                outlined: true
                onTriggered: root.toggleHideOffline()
              }

              ActionButton {
                visible: root.hiddenCount > 0 || root.showHidden
                label: root.showHidden ? "Done" : "Show hidden (" + root.hiddenCount + ")"
                outlined: !root.showHidden
                onTriggered: root.showHidden = !root.showHidden
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.configured && root.cameras.length > 0
              width: parent.width
              text: "Click or Enter for live  ·  P pop out  ·  W wall  ·  "
                  + root.consoles.map(function(c) { return c.name }).join(", ")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
